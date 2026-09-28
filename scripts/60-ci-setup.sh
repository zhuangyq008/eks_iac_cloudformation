#!/usr/bin/env bash
# =============================================================================
#  60-ci-setup.sh —— 可选扩展：AWS 之外的 Jenkins 推 ECR + 部署 EKS
#
#  推镜像（config.env 的 CI_ECR_AUTH）：
#    accesskey     IAM 用户静态 AK/SK，只能推拉 ${PROJECT}/* 仓库，默认只能从 Jenkins 出口 IP 使用
#    rolesanywhere 自建 CA 签发客户端证书，Jenkins 用证书换 1 小时临时凭证，没有长期密钥
#  部署  ：K8s ServiceAccount token 的 kubeconfig，只对 CI_NAMESPACES 有权限，不需要 aws CLI
#  产物  ：一个交接目录（AK/SK 或证书、kubeconfig、参数），按 docs/jenkins-cicd.md 导入 Jenkins
#  配置项见 config.env 的「扩展：外部 Jenkins CI/CD」段。独立于 02-deploy / 99-destroy。
#
#  用法：
#    ./scripts/60-ci-setup.sh                 # 部署 / 更新（幂等），结束后自动验收
#    ./scripts/60-ci-setup.sh info            # 打印交接目录与 Jenkins 配置要点
#    ./scripts/60-ci-setup.sh verify          # 模拟 Jenkins：屏蔽本机 AWS 凭证，只用交接目录里的文件
#    ./scripts/60-ci-setup.sh kubeconfig      # 重新生成交接目录里的 kubeconfig（集群端点 / CA 变了时）
#    ./scripts/60-ci-setup.sh rotate-token    # 吊销并重建 SA token（旧 kubeconfig 立即失效）
#    ./scripts/60-ci-setup.sh rotate-key      # accesskey：新建 AK/SK，确认 Jenkins 已更新后删除旧的
#    ./scripts/60-ci-setup.sh rotate-cert     # rolesanywhere：换发客户端证书（旧证书到期前仍有效）
#    ./scripts/60-ci-setup.sh destroy         # 删除 RBAC、访问密钥与本栈（ECR 仓库与 CA 保留）
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JENKINS_EGRESS_CIDRS="${JENKINS_EGRESS_CIDRS:-}"
CI_ECR_AUTH="${CI_ECR_AUTH:-accesskey}"
CI_KEY_LOCK_SOURCE_IP="${CI_KEY_LOCK_SOURCE_IP:-true}"
CI_NAMESPACES="${CI_NAMESPACES:-app}"
CI_SA_NAME="${CI_SA_NAME:-jenkins-deployer}"
CI_ECR_REPOSITORIES="${CI_ECR_REPOSITORIES:-}"
CI_CERT_CN="${CI_CERT_CN:-${PROJECT}-${ENVIRONMENT}-jenkins}"
CI_CERT_DAYS="${CI_CERT_DAYS:-365}"
CI_CA_DAYS="${CI_CA_DAYS:-3650}"
CI_SIGNING_HELPER_VERSION="${CI_SIGNING_HELPER_VERSION:-1.7.0}"
STACK_CI="${STACK_CI:-${PROJECT}-${ENVIRONMENT}-ci-ecr}"

# CA 私钥只留在执行本脚本的环境（CloudShell 只持久化 $HOME），绝不放进交接目录
PKI_DIR="${CI_PKI_DIR:-${HOME}/.${PROJECT}-${ENVIRONMENT}-ci-pki}"
BUNDLE_DIR="${CI_BUNDLE_DIR:-${HOME}/${PROJECT}-${ENVIRONMENT}-jenkins-bundle}"
# rolesanywhere + 企业自有 PKI 时三个都要给（见文档「使用自有 CA」）；给了就不再自建 CA
CI_CA_CERT_FILE="${CI_CA_CERT_FILE:-}"
CI_CLIENT_CERT_FILE="${CI_CLIENT_CERT_FILE:-}"
CI_CLIENT_KEY_FILE="${CI_CLIENT_KEY_FILE:-}"

read -r -a NAMESPACES <<< "${CI_NAMESPACES//,/ }"
(( ${#NAMESPACES[@]} > 0 )) || die "CI_NAMESPACES 不能为空"
SA_NS="${NAMESPACES[0]}"
[[ "${CI_ECR_AUTH}" == "accesskey" || "${CI_ECR_AUTH}" == "rolesanywhere" ]] \
  || die "CI_ECR_AUTH 只能是 accesskey 或 rolesanywhere（当前 ${CI_ECR_AUTH}）"
CI_PRINCIPAL="${PROJECT}-${ENVIRONMENT}-ci-ecr-push"   # IAM 用户 / 角色名（与模板一致）

out() { stack_output "${STACK_CI}" "$1" | grep -v '^None$' || true; }

require_stack() {
  [[ "$(stack_status "${STACK_CI}")" == *_COMPLETE && "$(stack_status "${STACK_CI}")" != *ROLLBACK* ]] \
    || die "栈 ${STACK_CI} 未部署成功（当前 $(stack_status "${STACK_CI}")），先执行 ./scripts/60-ci-setup.sh"
  [[ "$(out AuthMode)" == "${CI_ECR_AUTH}" ]] \
    || die "栈 ${STACK_CI} 是 $(out AuthMode) 模式，config.env 是 ${CI_ECR_AUTH}。切换模式请重新执行部署"
}

valid_cidrs() {
  python3 - "$1" 2>/dev/null <<'PY'
import ipaddress, sys
items = [c for c in sys.argv[1].split(",") if c]
assert items
for c in items:
    ipaddress.IPv4Network(c, strict=True)
PY
}

# accesskey 模式下访问密钥只能从这些 CIDR 使用；输出空 = 不限来源
source_ip_lock() {
  [[ "${CI_ECR_AUTH}" == "accesskey" && "${CI_KEY_LOCK_SOURCE_IP}" == "true" ]] && echo "${JENKINS_EGRESS_CIDRS// /}"
  return 0
}

# ---------------------------------------------------------------- 证书（rolesanywhere）
openssl_conf() {
  # openssl_conf <CN> —— Subject 直接写进 dn 段：LibreSSL（macOS）在带 -config 时会忽略 -subj
  cat <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
O = ${PROJECT}
CN = $1
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[v3_client]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
}

ca_cert()     { [[ -n "${CI_CA_CERT_FILE}" ]] && echo "${CI_CA_CERT_FILE}" || echo "${PKI_DIR}/ca.pem"; }
client_cert() { [[ -n "${CI_CLIENT_CERT_FILE}" ]] && echo "${CI_CLIENT_CERT_FILE}" || echo "${PKI_DIR}/client.pem"; }
client_key()  { [[ -n "${CI_CLIENT_KEY_FILE}" ]] && echo "${CI_CLIENT_KEY_FILE}" || echo "${PKI_DIR}/client.key"; }

ensure_ca() {
  if [[ -n "${CI_CA_CERT_FILE}" ]]; then
    [[ -f "${CI_CA_CERT_FILE}" && -f "${CI_CLIENT_CERT_FILE}" && -f "${CI_CLIENT_KEY_FILE}" ]] \
      || die "使用自有 CA 时 CI_CA_CERT_FILE / CI_CLIENT_CERT_FILE / CI_CLIENT_KEY_FILE 三个文件都要存在"
    ok "使用自有 CA ${CI_CA_CERT_FILE}"
    return 0
  fi
  mkdir -p "${PKI_DIR}" && chmod 700 "${PKI_DIR}"
  if [[ -f "${PKI_DIR}/ca.pem" && -f "${PKI_DIR}/ca.key" ]]; then
    ok "沿用已有 CA ${PKI_DIR}/ca.pem（到期 $(openssl x509 -in "${PKI_DIR}/ca.pem" -noout -enddate | cut -d= -f2)）"
    return 0
  fi
  log "自建 CA（EC P-256，有效期 ${CI_CA_DAYS} 天）"
  openssl_conf "${PROJECT}-${ENVIRONMENT}-ci-ca" > "${PKI_DIR}/openssl.cnf"
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "${PKI_DIR}/ca.key" )
  openssl req -x509 -new -key "${PKI_DIR}/ca.key" -sha256 -days "${CI_CA_DAYS}" \
    -config "${PKI_DIR}/openssl.cnf" -extensions v3_ca -out "${PKI_DIR}/ca.pem"
  ok "CA 已生成：${PKI_DIR}/ca.pem（私钥 ca.key 只保存在本机，请备份到安全位置）"
}

issue_client_cert() {
  # issue_client_cert [force]
  [[ -z "${CI_CA_CERT_FILE}" ]] || return 0
  if [[ -z "${1:-}" && -f "${PKI_DIR}/client.pem" ]] \
     && openssl x509 -in "${PKI_DIR}/client.pem" -noout -checkend $((30 * 86400)) >/dev/null; then
    ok "沿用已有客户端证书（到期 $(openssl x509 -in "${PKI_DIR}/client.pem" -noout -enddate | cut -d= -f2)）"
    return 0
  fi
  log "签发客户端证书 CN=${CI_CERT_CN}（有效期 ${CI_CERT_DAYS} 天）"
  openssl_conf "${CI_CERT_CN}" > "${PKI_DIR}/openssl.cnf"
  if [[ -f "${PKI_DIR}/client.pem" ]]; then
    local ts; ts="$(date +%Y%m%d%H%M%S)"
    mv "${PKI_DIR}/client.pem" "${PKI_DIR}/client.pem.${ts}"
    mv "${PKI_DIR}/client.key" "${PKI_DIR}/client.key.${ts}"
  fi
  ( umask 077
    openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "${PKI_DIR}/client.key" )
  openssl req -new -key "${PKI_DIR}/client.key" \
    -config "${PKI_DIR}/openssl.cnf" -out "${PKI_DIR}/client.csr"
  openssl x509 -req -in "${PKI_DIR}/client.csr" -CA "${PKI_DIR}/ca.pem" -CAkey "${PKI_DIR}/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "${CI_CERT_DAYS}" -sha256 \
    -extfile "${PKI_DIR}/openssl.cnf" -extensions v3_client -out "${PKI_DIR}/client.pem" 2>/dev/null
  rm -f "${PKI_DIR}/client.csr"
  openssl verify -CAfile "${PKI_DIR}/ca.pem" "${PKI_DIR}/client.pem" >/dev/null || die "客户端证书校验失败"
  openssl x509 -in "${PKI_DIR}/client.pem" -noout -subject | grep -q "CN *= *${CI_CERT_CN}\$" \
    || die "客户端证书 Subject 不是 CN=${CI_CERT_CN}：$(openssl x509 -in "${PKI_DIR}/client.pem" -noout -subject)"
  ok "客户端证书：${PKI_DIR}/client.pem（序列号 $(openssl x509 -in "${PKI_DIR}/client.pem" -noout -serial | cut -d= -f2)）"
}

# ---------------------------------------------------------------- 访问密钥（accesskey）
# 密钥只用 CLI 创建并直接写进交接目录：不进 CFN 参数 / 输出，AWS 侧事后只能看到 Key ID
bundle_key_id() { sed -n 's/^aws_access_key_id = //p' "${BUNDLE_DIR}/aws-credentials" 2>/dev/null || true; }
user_key_ids() {
  aws iam list-access-keys --user-name "${CI_PRINCIPAL}" --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

create_access_key() {
  local json
  json="$(aws iam create-access-key --user-name "${CI_PRINCIPAL}" --output json)"
  mkdir -p "${BUNDLE_DIR}" && chmod 700 "${BUNDLE_DIR}"
  ( umask 077
    python3 -c '
import json, sys
k = json.loads(sys.argv[1])["AccessKey"]
d, region = sys.argv[2], sys.argv[3]
open(d + "/aws-credentials", "w").write(
    "[ci-ecr]\naws_access_key_id = %s\naws_secret_access_key = %s\n" % (k["AccessKeyId"], k["SecretAccessKey"]))
open(d + "/ecr-access-key.txt", "w").write(
    "AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_REGION=%s\n" % (k["AccessKeyId"], k["SecretAccessKey"], region))
' "${json}" "${BUNDLE_DIR}" "${AWS_REGION}" )
  ok "已创建访问密钥 $(bundle_key_id)（Secret 只写入 ${BUNDLE_DIR}，AWS 不会再次显示）"
}

ensure_access_key() {
  local have; have="$(bundle_key_id)"
  if [[ -n "${have}" ]] && user_key_ids | grep -qx "${have}"; then
    ok "沿用交接目录里的访问密钥 ${have}"
    return 0
  fi
  (( $(user_key_ids | wc -l) < 2 )) \
    || die "IAM 用户 ${CI_PRINCIPAL} 已有 2 把密钥且交接目录里没有其中任何一把。请在 IAM 控制台删除不用的密钥后重试"
  create_access_key
}

delete_all_access_keys() {
  local k
  for k in $(user_key_ids); do
    aws iam delete-access-key --user-name "${CI_PRINCIPAL}" --access-key-id "${k}" && ok "已删除访问密钥 ${k}"
  done
}

# ---------------------------------------------------------------- AWS 侧
deploy_ci_stack() {
  if [[ "${CI_ECR_AUTH}" == "accesskey" ]]; then
    deploy_stack "${STACK_CI}" "${CFN_DIR}/60-ci-ecr.yaml" \
      "ProjectName=${PROJECT}" "EnvironmentName=${ENVIRONMENT}" \
      "AuthMode=accesskey" "SourceIpCidrs=$(source_ip_lock)" \
      "CaCertificatePem=" "AllowedCertCn=${CI_CERT_CN}"
  else
    # 从 accesskey 切过来：IAM 用户名下还有密钥时 CFN 删不掉用户
    [[ "$(out AuthMode)" == "accesskey" ]] && delete_all_access_keys
    deploy_stack "${STACK_CI}" "${CFN_DIR}/60-ci-ecr.yaml" \
      "ProjectName=${PROJECT}" "EnvironmentName=${ENVIRONMENT}" \
      "AuthMode=rolesanywhere" "SourceIpCidrs=" \
      "CaCertificatePem=$(cat "$(ca_cert)")" "AllowedCertCn=${CI_CERT_CN}"
  fi
}

ensure_ecr_repos() {
  local r name
  for r in ${CI_ECR_REPOSITORIES//,/ }; do
    name="${PROJECT}/${r}"
    if aws ecr describe-repositories --repository-names "${name}" >/dev/null 2>&1; then
      ok "ECR 仓库 ${name} 已存在"
    else
      aws ecr create-repository --repository-name "${name}" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
      ok "ECR 仓库 ${name} 已创建（推送时自动漏洞扫描）"
    fi
  done
}

allow_jenkins_egress() {
  local want="${JENKINS_EGRESS_CIDRS// /}" cur missing="" c new
  if [[ -z "${want}" ]]; then
    warn "JENKINS_EGRESS_CIDRS 为空：Jenkins 出口 IP 不在 EKS 公共端点白名单时 kubectl 会 i/o timeout"
    return 0
  fi
  cur="$(public_access_cidrs)"
  if grep -qx '0.0.0.0/0' <<< "${cur}"; then
    ok "EKS 公共端点对 0.0.0.0/0 开放，无需追加 Jenkins 出口"; return 0
  fi
  for c in ${want//,/ }; do grep -qx "${c}" <<< "${cur}" || missing="${missing} ${c}"; done
  if [[ -z "${missing}" ]]; then ok "Jenkins 出口 ${want} 已在 EKS 公共端点白名单内"; return 0; fi
  # 追加而不是替换：不能把正在用的 CloudShell / 办公网踢出去
  # shellcheck disable=SC2086
  new=$(printf '%s\n' ${cur} ${missing} | grep -v '^$' | sort -u | paste -sd, -)
  log "把 Jenkins 出口${missing} 追加到 EKS 公共端点白名单"
  wait_eks_update "$(aws eks update-cluster-config --name "${CLUSTER_NAME}" \
    --resources-vpc-config "publicAccessCidrs=${new},endpointPublicAccess=true,endpointPrivateAccess=true" \
    --query 'update.id' --output text)" || die "更新白名单失败"
  ok "白名单已更新：${new}"
  warn "这是带外修改，${STACK_CLUSTER} 栈会出现漂移。请把 Jenkins 出口同步进 config.env 的 API_PUBLIC_ACCESS_CIDRS"
}

# ---------------------------------------------------------------- K8s 侧
rbac_manifest() {
  # rbac_manifest <target-namespace>
  sed -e "s/__SA_NAMESPACE__/${SA_NS}/g" -e "s/__NAMESPACE__/$1/g" -e "s/__SA_NAME__/${CI_SA_NAME}/g" \
    "${MANIFEST_DIR}/ci-deployer-rbac.yaml"
}

apply_rbac() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    kubectl get ns "${ns}" >/dev/null 2>&1 || { kubectl create ns "${ns}" >/dev/null && ok "已创建命名空间 ${ns}"; }
    rbac_manifest "${ns}" | kubectl apply -f - >/dev/null
    ok "命名空间 ${ns}：Role / RoleBinding -> ${SA_NS}/${CI_SA_NAME}"
  done
}

sa_token() {
  local t
  for _ in $(seq 1 30); do
    t=$(kubectl -n "${SA_NS}" get secret "${CI_SA_NAME}-token" -o jsonpath='{.data.token}' 2>/dev/null || true)
    [[ -n "${t}" ]] && { base64 -d <<< "${t}"; return 0; }
    sleep 2
  done
  return 1
}

write_kubeconfig() {
  local ep ca token file="${BUNDLE_DIR}/kubeconfig"
  ep="$(cluster_api_endpoint)"
  ca="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.certificateAuthority.data' --output text)"
  token="$(sa_token)" || die "SA token Secret ${SA_NS}/${CI_SA_NAME}-token 没有生成 token"
  mkdir -p "${BUNDLE_DIR}" && chmod 700 "${BUNDLE_DIR}"
  ( umask 077; cat > "${file}" <<EOF
# ${CLUSTER_NAME} 的 CI 部署账号 ${SA_NS}/${CI_SA_NAME}（由 60-ci-setup.sh 生成）
# 使用 ServiceAccount token 认证，不需要 aws CLI 与 AWS 凭证。权限仅限命名空间：${CI_NAMESPACES}
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${ep}
      certificate-authority-data: ${ca}
users:
  - name: ${CI_SA_NAME}
    user:
      token: ${token}
contexts:
  - name: ${CI_SA_NAME}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${CI_SA_NAME}
      namespace: ${SA_NS}
current-context: ${CI_SA_NAME}@${CLUSTER_NAME}
EOF
  )
  ok "kubeconfig：${file}"
}

# ---------------------------------------------------------------- 交接目录
write_bundle() {
  mkdir -p "${BUNDLE_DIR}" && chmod 700 "${BUNDLE_DIR}"
  local registry lock; registry="$(out EcrRegistry)"; lock="$(source_ip_lock)"
  if [[ "${CI_ECR_AUTH}" == "accesskey" ]]; then
    rm -f "${BUNDLE_DIR}/client.pem" "${BUNDLE_DIR}/client.key"
    ( umask 077; cat > "${BUNDLE_DIR}/jenkins.env" <<EOF
# 非机密参数：在 Jenkins「系统管理 -> 系统配置 -> 全局属性 -> 环境变量」里逐项添加，
# 或直接写进 Jenkinsfile 的 environment 块
CI_ECR_AUTH=accesskey
AWS_REGION=${AWS_REGION}
ECR_REGISTRY=${registry}
ECR_REPO_PREFIX=${PROJECT}
EKS_CLUSTER=${CLUSTER_NAME}
K8S_NAMESPACES=${CI_NAMESPACES}
EOF
    )
    ( umask 077; printf '[profile ci-ecr]\nregion = %s\n' "${AWS_REGION}" > "${BUNDLE_DIR}/aws-config" )
    cat > "${BUNDLE_DIR}/README.txt" <<EOF
交接给 Jenkins 管理员的文件（导入方法见交付包 docs/jenkins-cicd.md）

  ecr-access-key.txt  Username with password 凭据，ID 建议 ecr-push-key（机密）
                      Username = AWS_ACCESS_KEY_ID，Password = AWS_SECRET_ACCESS_KEY
  kubeconfig          Secret file 凭据，ID 建议 eks-kubeconfig（机密）
  jenkins.env         非机密参数（仓库地址等），配成 Jenkins 全局环境变量
  aws-config / aws-credentials  仅供本机 verify / 调试，不需要导入 Jenkins

访问密钥只能推拉 ${PROJECT}/* 仓库${lock:+，且只能从 ${lock} 使用}。
ecr-access-key.txt 与 kubeconfig 是凭证，传输请走加密渠道，导入 Jenkins 后删除本地副本。
EOF
  else
    rm -f "${BUNDLE_DIR}/aws-credentials" "${BUNDLE_DIR}/ecr-access-key.txt"
    install -m 600 "$(client_cert)" "${BUNDLE_DIR}/client.pem"
    install -m 600 "$(client_key)"  "${BUNDLE_DIR}/client.key"
    ( umask 077; cat > "${BUNDLE_DIR}/jenkins.env" <<EOF
# 非机密参数：在 Jenkins「系统管理 -> 系统配置 -> 全局属性 -> 环境变量」里逐项添加，
# 或直接写进 Jenkinsfile 的 environment 块
CI_ECR_AUTH=rolesanywhere
AWS_REGION=${AWS_REGION}
ECR_REGISTRY=${registry}
ECR_REPO_PREFIX=${PROJECT}
RA_TRUST_ANCHOR_ARN=$(out TrustAnchorArn)
RA_PROFILE_ARN=$(out ProfileArn)
RA_ROLE_ARN=$(out RoleArn)
EKS_CLUSTER=${CLUSTER_NAME}
K8S_NAMESPACES=${CI_NAMESPACES}
EOF
    )
    ( umask 077; cat > "${BUNDLE_DIR}/aws-config" <<EOF
[profile ci-ecr]
region = ${AWS_REGION}
credential_process = aws_signing_helper credential-process --certificate ${BUNDLE_DIR}/client.pem --private-key ${BUNDLE_DIR}/client.key --trust-anchor-arn $(out TrustAnchorArn) --profile-arn $(out ProfileArn) --role-arn $(out RoleArn)
EOF
    )
    cat > "${BUNDLE_DIR}/README.txt" <<EOF
交接给 Jenkins 管理员的文件（导入方法见交付包 docs/jenkins-cicd.md）

  client.pem   Secret file 凭据，ID 建议 ecr-ra-cert     Roles Anywhere 客户端证书
  client.key   Secret file 凭据，ID 建议 ecr-ra-key      客户端证书私钥（机密）
  kubeconfig   Secret file 凭据，ID 建议 eks-kubeconfig  EKS 部署账号（机密）
  jenkins.env  非机密参数（ARN / 仓库地址），配成 Jenkins 全局环境变量
  aws-config   仅供本机 verify / 调试，不需要导入 Jenkins

client.key 与 kubeconfig 是凭证，传输请走加密渠道，导入 Jenkins 后删除本地副本。
EOF
  fi
  ok "交接目录：${BUNDLE_DIR}"
}

# ---------------------------------------------------------------- 模拟 Jenkins
signing_helper() {
  command -v aws_signing_helper >/dev/null 2>&1 && { command -v aws_signing_helper; return 0; }
  local bin="${HOME}/.local/bin/aws_signing_helper" os arch
  [[ -x "${bin}" ]] && { echo "${bin}"; return 0; }
  case "$(uname -s)" in Linux) os=Linux ;; Darwin) os=Darwin ;; *) die "不支持的系统 $(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=X86_64 ;; aarch64|arm64) arch=Aarch64 ;; *) die "不支持的架构 $(uname -m)" ;; esac
  mkdir -p "$(dirname "${bin}")"
  curl -fsSL -o "${bin}" "https://rolesanywhere.amazonaws.com/releases/${CI_SIGNING_HELPER_VERSION}/${arch}/${os}/aws_signing_helper" \
    || die "下载 aws_signing_helper ${CI_SIGNING_HELPER_VERSION} 失败"
  chmod +x "${bin}"
  echo "${bin}"
}

# 清掉本机所有 AWS 凭证来源（环境变量 / profile / CloudShell 容器凭证 / IMDS），只留交接目录
as_jenkins() {
  local creds=/dev/null path_prefix=""
  [[ "${CI_ECR_AUTH}" == "accesskey" ]] && creds="${BUNDLE_DIR}/aws-credentials"
  [[ "${CI_ECR_AUTH}" == "rolesanywhere" ]] && path_prefix="$(dirname "$(signing_helper)"):"
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
      -u AWS_CONTAINER_CREDENTIALS_FULL_URI -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -u AWS_CONTAINER_AUTHORIZATION_TOKEN \
      -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_ROLE_ARN \
      AWS_CONFIG_FILE="${BUNDLE_DIR}/aws-config" AWS_SHARED_CREDENTIALS_FILE="${creds}" \
      AWS_EC2_METADATA_DISABLED=true AWS_REGION="${AWS_REGION}" AWS_DEFAULT_REGION="${AWS_REGION}" \
      KUBECONFIG="${BUNDLE_DIR}/kubeconfig" PATH="${path_prefix}${PATH}" "$@"
}

ip_in_cidrs() {
  python3 - "$1" "$2" 2>/dev/null <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(c) for c in sys.argv[2].split(",") if c) else 1)
PY
}

# ---------------------------------------------------------------- 子命令
cmd_deploy() {
  local lock; lock="$(source_ip_lock)"
  section "外部 Jenkins CI/CD 部署计划"
  cat <<EOF
  Stack          : ${STACK_CI}
  ECR 认证方式   : ${CI_ECR_AUTH}$( [[ "${CI_ECR_AUTH}" == "accesskey" ]] \
                      && echo "（IAM 用户 ${CI_PRINCIPAL}，来源 IP：${lock:-不限}）" \
                      || echo "（证书 CN=${CI_CERT_CN}，有效期 ${CI_CERT_DAYS} 天）" )
  ECR 仓库       : $(for r in ${CI_ECR_REPOSITORIES//,/ }; do printf '%s/%s ' "${PROJECT}" "${r}"; done)（权限范围 ${PROJECT}/*）
  部署命名空间   : ${CI_NAMESPACES}（SA ${SA_NS}/${CI_SA_NAME}）
  Jenkins 出口   : ${JENKINS_EGRESS_CIDRS:-（未填）}
  交接目录       : ${BUNDLE_DIR}
EOF
  need_cmd kubectl; need_cmd python3
  [[ -z "${JENKINS_EGRESS_CIDRS// /}" ]] || valid_cidrs "${JENKINS_EGRESS_CIDRS// /}" \
    || die "JENKINS_EGRESS_CIDRS 不合法：${JENKINS_EGRESS_CIDRS}（要求逗号分隔的 IPv4 CIDR）"
  if [[ "${CI_ECR_AUTH}" == "accesskey" && -z "${lock}" ]]; then
    warn "访问密钥不限来源 IP：一旦泄露，任何地方都能用它推送 / 覆盖 ${PROJECT}/* 的镜像"
    warn "建议填写 JENKINS_EGRESS_CIDRS 并保持 CI_KEY_LOCK_SOURCE_IP=true"
    confirm "仍然继续？" || die "已取消"
  fi
  confirm "开始部署？" || die "已取消"

  section "1/4 ECR 身份"
  if [[ "${CI_ECR_AUTH}" == "rolesanywhere" ]]; then
    need_cmd openssl
    ensure_ca
    issue_client_cert
  fi
  deploy_ci_stack
  [[ "${CI_ECR_AUTH}" == "accesskey" ]] && ensure_access_key
  ensure_ecr_repos

  section "2/4 EKS 部署账号"
  setup_kubeconfig
  apply_rbac

  section "3/4 EKS 公共端点白名单"
  allow_jenkins_egress

  section "4/4 交接目录"
  write_kubeconfig
  write_bundle

  cmd_verify
  cmd_info
}

cmd_info() {
  require_stack
  section "Jenkins 配置要点（详见 docs/jenkins-cicd.md）"
  printf '  交接目录：%s\n' "${BUNDLE_DIR}"
  ls -l "${BUNDLE_DIR}" 2>/dev/null | tail -n +2 | sed 's/^/    /'
  echo
  if [[ "${CI_ECR_AUTH}" == "accesskey" ]]; then
    cat <<EOF
  1) Jenkins 机器装好：docker、kubectl、aws CLI v2（文档第 3 节）
  2) 新建凭据：ecr-push-key = Username with password（ecr-access-key.txt 里的 AK / SK）
              eks-kubeconfig = Secret file（kubeconfig）
EOF
  else
    cat <<EOF
  1) Jenkins 机器装好：docker、kubectl、aws CLI v2、aws_signing_helper（文档第 3 节）
  2) 新建凭据：ecr-ra-cert = Secret file（client.pem）   ecr-ra-key = Secret file（client.key）
              eks-kubeconfig = Secret file（kubeconfig）
  证书到期：$(openssl x509 -in "${BUNDLE_DIR}/client.pem" -noout -enddate 2>/dev/null | cut -d= -f2)，到期前执行 rotate-cert
EOF
  fi
  cat <<EOF
  3) 把 jenkins.env 里的变量配成全局环境变量
  4) 参考交付包 ci/Jenkinsfile.example 编写流水线
  5) Jenkins 出口 IP 必须在 EKS 公共端点白名单里：$(public_access_cidrs | paste -sd, -)
EOF
}

cmd_verify() {
  require_stack
  [[ -f "${BUNDLE_DIR}/kubeconfig" && -f "${BUNDLE_DIR}/aws-config" ]] || die "交接目录 ${BUNDLE_DIR} 不完整，先执行部署"
  section "验收：模拟 Jenkins（屏蔽本机 AWS 凭证，只用交接目录）"
  local fail=0 arn ns repo myip lock expect_ok=1 want
  myip="$(my_egress_ip)"; lock="$(source_ip_lock)"
  if [[ "${CI_ECR_AUTH}" == "accesskey" ]]; then
    want=":user/${CI_PRINCIPAL}"
    # 锁了来源 IP 而本机不在 Jenkins 出口里：此时"被拒"才是正确结果
    if [[ -n "${lock}" ]] && ! ip_in_cidrs "${myip}" "${lock}"; then expect_ok=0; fi
  else
    want=":assumed-role/${CI_PRINCIPAL}/"
    signing_helper >/dev/null
  fi

  arn=$(as_jenkins aws --profile ci-ecr sts get-caller-identity --query Arn --output text 2>&1) || true
  [[ "${arn}" == *"${want}"* ]] && ok "身份：${arn}" || { err "取不到 CI 身份：${arn}"; fail=1; }

  if (( expect_ok )); then
    if [[ -n "$(as_jenkins aws --profile ci-ecr ecr get-login-password 2>/dev/null)" ]]; then
      ok "ecr get-login-password 成功（docker login 可用）"
    else
      err "ecr get-login-password 失败"; fail=1
    fi
    for repo in ${CI_ECR_REPOSITORIES//,/ }; do
      if as_jenkins aws --profile ci-ecr ecr describe-images --repository-name "${PROJECT}/${repo}" --max-items 1 >/dev/null 2>&1; then
        ok "可访问仓库 ${PROJECT}/${repo}"
      else
        err "无法访问仓库 ${PROJECT}/${repo}"; fail=1
      fi
    done
  else
    if as_jenkins aws --profile ci-ecr ecr get-login-password >/dev/null 2>&1; then
      err "本机出口 ${myip} 不在 ${lock} 内，却能用访问密钥登录 ECR —— 来源 IP 限制没生效"; fail=1
    else
      ok "来源 IP 限制生效：本机出口 ${myip} 不在 ${lock} 内，ECR 登录被拒"
      warn "ECR 推送的正向验证需要在 Jenkins 机器上做（文档「在 Jenkins 机器上自检」）"
    fi
  fi
  if as_jenkins aws --profile ci-ecr s3api list-buckets >/dev/null 2>&1; then
    err "CI 身份竟然能列 S3 桶，权限过大"; fail=1
  else
    ok "CI 身份没有 ECR 以外的权限（s3 list-buckets 被拒）"
  fi

  if as_jenkins kubectl get --raw /version --request-timeout=20s >/dev/null 2>&1; then
    ok "kubeconfig 可访问 API Server（本机出口 ${myip}）"
    for ns in "${NAMESPACES[@]}"; do
      [[ "$(as_jenkins kubectl auth can-i patch deployments -n "${ns}" 2>/dev/null)" == "yes" ]] \
        && ok "可以在 ${ns} 发布 Deployment" || { err "不能在 ${ns} 发布 Deployment"; fail=1; }
    done
    [[ "$(as_jenkins kubectl auth can-i create deployments -n kube-system 2>/dev/null)" == "no" ]] \
      && ok "不能动 kube-system" || { err "竟然可以动 kube-system"; fail=1; }
    [[ "$(as_jenkins kubectl auth can-i list nodes 2>/dev/null)" == "no" ]] \
      && ok "不能读集群级资源（nodes）" || { err "竟然可以读 nodes"; fail=1; }
  else
    warn "本机连不上 API Server（出口 ${myip} 可能不在白名单），kubeconfig 未验证"
  fi
  (( fail == 0 )) && ok "全部通过" || die "验收未通过"
}

cmd_kubeconfig() {
  setup_kubeconfig
  write_kubeconfig
  warn "请用新文件更新 Jenkins 凭据 eks-kubeconfig"
}

cmd_rotate_token() {
  warn "将吊销 ${SA_NS}/${CI_SA_NAME} 的 token：Jenkins 里现有的 kubeconfig 会立即失效"
  confirm "确认轮换？" || die "已取消"
  setup_kubeconfig
  kubectl -n "${SA_NS}" delete secret "${CI_SA_NAME}-token" --ignore-not-found >/dev/null
  apply_rbac
  write_kubeconfig
  warn "请立即用 ${BUNDLE_DIR}/kubeconfig 更新 Jenkins 凭据 eks-kubeconfig"
}

cmd_rotate_key() {
  [[ "${CI_ECR_AUTH}" == "accesskey" ]] || die "rotate-key 只用于 CI_ECR_AUTH=accesskey"
  require_stack
  local old k
  old="$(user_key_ids)"
  (( $(wc -w <<< "${old}") < 2 )) || die "IAM 用户 ${CI_PRINCIPAL} 已有 2 把密钥，先确认哪把在用并删掉另一把"
  create_access_key
  write_bundle
  warn "新密钥已写入 ${BUNDLE_DIR}/ecr-access-key.txt。旧密钥 ${old:-无} 仍然有效"
  warn "请先在 Jenkins 更新凭据 ecr-push-key 并跑通一次流水线，再回来确认删除旧密钥"
  confirm "Jenkins 已换成新密钥，删除旧密钥？" || { log "旧密钥保留。之后可重跑 rotate-key 或在 IAM 控制台删除"; return 0; }
  for k in ${old}; do
    aws iam delete-access-key --user-name "${CI_PRINCIPAL}" --access-key-id "${k}" && ok "已删除旧密钥 ${k}"
  done
}

cmd_rotate_cert() {
  [[ "${CI_ECR_AUTH}" == "rolesanywhere" ]] || die "rotate-cert 只用于 CI_ECR_AUTH=rolesanywhere"
  [[ -z "${CI_CA_CERT_FILE}" ]] || die "使用自有 CA 时请由企业 PKI 换发证书，再更新 CI_CLIENT_CERT_FILE / CI_CLIENT_KEY_FILE"
  require_stack
  issue_client_cert force
  write_bundle
  warn "请用 ${BUNDLE_DIR}/client.pem 与 client.key 更新 Jenkins 凭据 ecr-ra-cert / ecr-ra-key"
  warn "旧证书在到期前仍然有效。需要立即吊销时见 docs/jenkins-cicd.md「吊销证书」"
}

cmd_destroy() {
  warn "将删除：各命名空间的 CI Role / RoleBinding、SA ${SA_NS}/${CI_SA_NAME} 及其 token、访问密钥、栈 ${STACK_CI}"
  warn "保留：命名空间与其中的业务、ECR 仓库及镜像、CA 目录 ${PKI_DIR}、EKS 白名单"
  confirm "确认删除？" || die "已取消"
  local ns
  # 集群已删除时跳过 K8s 侧（RBAC 与 token 随集群一起没了），继续清理 IAM
  if ! aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    warn "集群 ${CLUSTER_NAME} 不存在，跳过 K8s 侧清理"
  elif setup_kubeconfig; then
    for ns in "${NAMESPACES[@]}"; do
      kubectl -n "${ns}" delete role,rolebinding "${CI_SA_NAME}" --ignore-not-found >/dev/null || true
    done
    kubectl -n "${SA_NS}" delete secret "${CI_SA_NAME}-token" --ignore-not-found >/dev/null || true
    kubectl -n "${SA_NS}" delete serviceaccount "${CI_SA_NAME}" --ignore-not-found >/dev/null || true
    ok "K8s 侧已清理（token 已吊销）"
  fi
  # 用户名下有密钥时 CFN 删不掉 IAM 用户
  [[ "$(out AuthMode)" == "accesskey" ]] && delete_all_access_keys
  delete_stack "${STACK_CI}"
  rm -rf "${BUNDLE_DIR}" && ok "已删除交接目录 ${BUNDLE_DIR}"
  printf '  %s\n' "ECR 仓库需要删除时：aws ecr delete-repository --repository-name ${PROJECT}/<repo> --force"
  [[ -z "${JENKINS_EGRESS_CIDRS}" ]] \
    || printf '  %s\n' "EKS 白名单里的 Jenkins 出口 ${JENKINS_EGRESS_CIDRS} 请用 ./scripts/allow-my-ip.sh --list 确认后按需移除"
  return 0
}

case "${1:-deploy}" in
  deploy)        cmd_deploy ;;
  info)          cmd_info ;;
  verify)        cmd_verify ;;
  kubeconfig)    cmd_kubeconfig ;;
  rotate-token)  cmd_rotate_token ;;
  rotate-key)    cmd_rotate_key ;;
  rotate-cert)   cmd_rotate_cert ;;
  destroy)       cmd_destroy ;;
  -h|--help)     awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" ;;
  *)             die "未知子命令: $1（见 --help）" ;;
esac
