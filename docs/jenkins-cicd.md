# 外部 Jenkins 接入：推送 ECR + 部署 EKS

适用场景：Jenkins **不在 AWS 上**（机房 / 办公网 / 其他云），要把镜像推到本交付包的 ECR，再发布到 EKS。
Jenkins 上**不需要 `aws configure`，也不需要 `~/.aws`**；所有凭证都以 Jenkins 凭据的形式导入，只在流水线步骤里临时生效。

本扩展完全独立：`02-deploy.sh` / `99-destroy.sh` 都不会碰它，部署与删除都用 `./scripts/60-ci-setup.sh`。

两种接入方式，按需选一种（也可以并存）：

| | 方式一：Jenkins 直推（第 1–9 节） | 方式二：跳板机构建（[第 10 节](#10-方式二跳板机构建jenkins-ssh-上传-jar)） |
|---|---|---|
| 镜像在哪构建 | Jenkins 节点（需要 docker） | AWS 上的 x86 跳板机（Jenkins 不需要 docker / aws CLI） |
| Jenkins 上的凭证 | ECR 推送凭证 + kubeconfig | 只有一把 SSH 私钥 |
| 输入 | 源码 / Dockerfile | 页面上传的 JAR（或前置阶段产出的 JAR） |
| 部署脚本 | `./scripts/60-ci-setup.sh` | `./scripts/50-bastion.sh` |

---

## 1. 架构

```
                     ┌──────────────── 客户 AWS 账号 ────────────────┐
 Jenkins（AWS 之外）  │                                              │
  出口 IP = JENKINS_EGRESS_CIDRS                                     │
   │                 │                                              │
   │ ① 推镜像        │  ECR  <ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com/<PROJECT>/*
   ├───────────────▶ │   IAM 身份只能推拉 <PROJECT>/* 仓库，其他 AWS 权限一律没有
   │  AK/SK 或 证书   │                                              │
   │                 │                                              │
   │ ② kubectl apply │  EKS 公共端点（白名单含 Jenkins 出口 IP）      │
   └───────────────▶ │   ServiceAccount token：只对 CI_NAMESPACES 有权限
      kubeconfig     │   不能动 kube-system，不能读节点等集群级资源   │
                     └──────────────────────────────────────────────┘
```

两条链路互不依赖：

| 链路 | 凭证 | AWS 侧 | 是否需要 aws CLI |
|---|---|---|---|
| 部署 EKS | kubeconfig（内含 K8s ServiceAccount token） | 无 IAM 身份；EKS 只认 token | **不需要** |
| 推送 ECR | 二选一，见下表 | 栈 `<PROJECT>-<ENV>-ci-ecr` | 需要（`aws ecr get-login-password`） |

### ECR 认证方式（`config.env` 的 `CI_ECR_AUTH`）

| | `accesskey`（**默认**） | `rolesanywhere` |
|---|---|---|
| Jenkins 里放什么 | 一对静态 AK/SK（Username with password 凭据） | 客户端证书 + 私钥（两个 Secret file 凭据） |
| 有效期 | 长期有效，直到轮换 / 删除 | 证书 365 天（`CI_CERT_DAYS`）；每次构建自动换 1 小时临时凭证，**不用人工续** |
| 权限 | 只能推拉 `<PROJECT>/*` 仓库 | 同左 |
| 泄露后的影响 | `CI_KEY_LOCK_SOURCE_IP=true`（默认）时**只能从 Jenkins 出口 IP 使用**，别处拿到也用不了 | 没有长期密钥；证书 CN 被锁定为 `CI_CERT_CN`，同一 CA 签的其他证书用不了 |
| Jenkins 额外依赖 | 无 | `aws_signing_helper`（一个静态二进制） |
| 适合 | 大多数客户；配置最简单 | 安全合规要求"不得使用长期访问密钥"的客户 |

> 两种方式都已在 AWS 之外的 Jenkins 上端到端实测通过：构建镜像 → 推 ECR → `kubectl apply` → 滚动发布成功 → 校验运行中的镜像版本（见第 9 节）。

---

## 2. 配置

编辑 `config.env` 的「扩展：外部 Jenkins CI/CD」段：

| 变量 | 默认 | 说明 |
|---|---|---|
| `JENKINS_EGRESS_CIDRS` | 空 | **【必改】** Jenkins 访问公网时的出口 IP（逗号分隔，如 `203.0.113.10/32`）。会**追加**进 EKS 公共端点白名单；`accesskey` 模式同时作为密钥的来源 IP 限制。在 Jenkins 机器上执行 `curl -s https://checkip.amazonaws.com` 即可得到。走代理出网时填代理的出口 IP |
| `CI_ECR_AUTH` | `accesskey` | `accesskey` 或 `rolesanywhere` |
| `CI_KEY_LOCK_SOURCE_IP` | `true` | `accesskey`：密钥只能从 `JENKINS_EGRESS_CIDRS` 使用。Jenkins 出口 IP 不固定时才设 `false` |
| `CI_NAMESPACES` | `app` | Jenkins 可以发布的命名空间，逗号分隔；不存在会自动创建 |
| `CI_SA_NAME` | `jenkins-deployer` | ServiceAccount 名（建在 `CI_NAMESPACES` 的第一个命名空间里） |
| `CI_ECR_REPOSITORIES` | `demo-app` | 需要预建的 ECR 仓库，自动加 `<PROJECT>/` 前缀（开启推送扫描、AES256 加密）。之后新增仓库：加进来重跑部署即可 |
| `CI_CERT_CN` | `<PROJECT>-<ENV>-jenkins` | `rolesanywhere`：客户端证书 CN，IAM 角色只信任这个 CN |
| `CI_CERT_DAYS` / `CI_CA_DAYS` | `365` / `3650` | `rolesanywhere`：客户端证书 / 自建 CA 有效期（天） |

---

## 3. 部署（在 CloudShell 里执行，约 3–5 分钟）

前提：EKS 已按 README 部署完成；`kubectl` 已装（`install-tools.sh`）；执行者的 IAM 身份有 CloudFormation、IAM、ECR、EKS（改白名单）权限，`rolesanywhere` 模式另需 Roles Anywhere 权限。

```bash
vi config.env                          # 至少填 JENKINS_EGRESS_CIDRS
./scripts/60-ci-setup.sh               # 部署 / 更新（幂等），结束后自动验收
./scripts/60-ci-setup.sh info          # 再次查看交接目录与 Jenkins 配置要点
./scripts/60-ci-setup.sh verify        # 重新验收（屏蔽本机 AWS 凭证，只用交接目录里的文件）
```

脚本做了什么：

1. 部署栈 `<PROJECT>-<ENV>-ci-ecr`：ECR 推送策略 + IAM 用户（`accesskey`）或 Trust Anchor / Profile / 角色（`rolesanywhere`）
2. `accesskey`：用 CLI 给 IAM 用户创建访问密钥。**Secret 只写进交接目录，不经过 CloudFormation，AWS 也不会再次显示**
   `rolesanywhere`：自建 CA（私钥留在 `~/.<PROJECT>-<ENV>-ci-pki/`，**不进交接目录**），签发客户端证书
3. 预建 `CI_ECR_REPOSITORIES` 里的 ECR 仓库
4. 在 `CI_NAMESPACES` 里创建 ServiceAccount、token Secret、Role / RoleBinding（见 `manifests/ci-deployer-rbac.yaml`）
5. 把 `JENKINS_EGRESS_CIDRS` **追加**进 EKS 公共端点白名单（只加不删）
6. 生成交接目录 `~/<PROJECT>-<ENV>-jenkins-bundle/`，然后自动 verify

verify 会以"Jenkins 视角"检查：身份正确、ECR 可登录、**除 ECR 以外没有任何 AWS 权限**（`s3 list-buckets` 必须被拒）、kubeconfig 能在目标命名空间发布 Deployment、**不能**动 `kube-system`、**不能**读节点。

> `accesskey` + IP 锁定时，CloudShell 的出口 IP 不在 Jenkins 白名单里，verify 会显示「来源 IP 限制生效…ECR 登录被拒」——这是**预期结果**，说明锁定生效。ECR 推送的正向验证请在 Jenkins 机器上做（第 6 节）。

### 交接目录

| 文件 | 机密 | 用途 |
|---|---|---|
| `kubeconfig` | **是** | Jenkins 凭据 `eks-kubeconfig`（Secret file） |
| `ecr-access-key.txt` | **是** | `accesskey`：Jenkins 凭据 `ecr-push-key`（Username = `AWS_ACCESS_KEY_ID`，Password = `AWS_SECRET_ACCESS_KEY`） |
| `client.pem` / `client.key` | **是**（key） | `rolesanywhere`：Jenkins 凭据 `ecr-ra-cert` / `ecr-ra-key`（Secret file） |
| `jenkins.env` | 否 | 仓库地址、区域等参数，配成 Jenkins 全局环境变量 |
| `aws-config` / `aws-credentials` | 是 | 仅供 verify / 调试，**不需要**导入 Jenkins |
| `README.txt` | 否 | 简要说明 |

从 CloudShell 取出：`cd ~ && zip -r jenkins-bundle.zip <PROJECT>-<ENV>-jenkins-bundle`，再用「Actions → Download file」下载。
**走加密渠道交给 Jenkins 管理员，导入 Jenkins 后删除所有本地副本**（CloudShell 里的可保留，便于轮换）。

---

## 4. Jenkins 侧配置

### 4.1 Jenkins 节点（执行构建的 agent）

| 组件 | 说明 |
|---|---|
| Docker | 构建与推送镜像；Jenkins 运行用户要能访问 docker（加入 `docker` 组或挂载 socket） |
| `kubectl` | 与集群版本相差不超过 ±1 个小版本 |
| AWS CLI v2 | 只用来 `aws ecr get-login-password`，**不需要** `aws configure` |
| `aws_signing_helper` | 仅 `rolesanywhere`。下载：`https://rolesanywhere.amazonaws.com/releases/1.7.0/X86_64/Linux/aws_signing_helper`（arm64 把 `X86_64` 换成 `Aarch64`），`chmod +x` 放进 `PATH` |

插件：Pipeline、Credentials Binding、Plain Credentials（Secret file）、Timestamper（示例流水线用了 `timestamps()`）。

网络：Jenkins 需能访问 `api.ecr.<region>.amazonaws.com`、`<ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com`、S3（ECR 镜像层）、EKS 公共端点（`kubeconfig` 里的 `server`）、`sts.<region>.amazonaws.com`；`rolesanywhere` 另需 `rolesanywhere.<region>.amazonaws.com`。均为 443 出站。

### 4.2 凭据（系统管理 → 凭据 → 全局）

| ID（示例 Jenkinsfile 用这些 ID） | 类型 | 内容 |
|---|---|---|
| `eks-kubeconfig` | Secret file | 交接目录的 `kubeconfig` |
| `ecr-push-key` | Username with password | `accesskey`：Username = AK，Password = SK（见 `ecr-access-key.txt`） |
| `ecr-ra-cert` | Secret file | `rolesanywhere`：`client.pem` |
| `ecr-ra-key` | Secret file | `rolesanywhere`：`client.key` |

只导入所选模式需要的那组即可。

### 4.3 全局环境变量（系统管理 → 系统配置 → 全局属性 → 环境变量）

把 `jenkins.env` 里的每一行加进去（也可以直接写进 Jenkinsfile 的 `environment` 块）：

```
CI_ECR_AUTH=accesskey
AWS_REGION=<region>
ECR_REGISTRY=<ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com
ECR_REPO_PREFIX=<PROJECT>
EKS_CLUSTER=<集群名>
K8S_NAMESPACES=app
# rolesanywhere 模式另有 RA_TRUST_ANCHOR_ARN / RA_PROFILE_ARN / RA_ROLE_ARN
```

### 4.4 流水线

`ci/Jenkinsfile.example` 是完整示例：**构建镜像 → 推送 ECR → 部署 EKS → 校验运行中的镜像版本**。

- 新建 Pipeline 任务，把它粘进「Pipeline script」即可试跑：工作区没有 `Dockerfile` 时会自动生成一个 nginx 演示应用，一次验证 ECR 与 EKS 两条链路（推到 `<PROJECT>/demo-app`，部署到 `app` 命名空间）。
- 接入真实项目：放进代码仓库根目录作为 `Jenkinsfile`，删掉「准备演示应用」阶段，把 `k8s/deployment.yaml` 换成项目自己的清单（保留 `__IMAGE__` 占位符，或改用 Helm / Kustomize）。
- 参数：`APP_NAME`（ECR 仓库名 = Deployment 名）、`K8S_NAMESPACE`（须在 `CI_NAMESPACES` 内）、`IMAGE_PLATFORM`（与节点架构一致：x86 节点 `linux/amd64`，Graviton 节点 `linux/arm64`）。

关键写法（按 `CI_ECR_AUTH` 自动切换，凭证只在闭包内有效，日志中自动打码）：

```groovy
// accesskey：AK/SK 只注入这一步的环境变量
withCredentials([usernamePassword(credentialsId: 'ecr-push-key',
                 usernameVariable: 'AWS_ACCESS_KEY_ID', passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
  sh 'aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"'
  sh 'docker push "$IMAGE"'
}
// rolesanywhere：临时 AWS_CONFIG_FILE 里配 credential_process，aws CLI 需要时自动用证书换 1 小时凭证
//   credential_process = aws_signing_helper credential-process --certificate <cert> --private-key <key>
//                        --trust-anchor-arn $RA_TRUST_ANCHOR_ARN --profile-arn $RA_PROFILE_ARN --role-arn $RA_ROLE_ARN
// 部署：kubeconfig 只在这一步可见
withCredentials([file(credentialsId: 'eks-kubeconfig', variable: 'KUBECONFIG')]) {
  sh 'kubectl -n "$K8S_NAMESPACE" apply -f k8s/ && kubectl -n "$K8S_NAMESPACE" rollout status deploy/"$APP_NAME"'
}
```

`docker login` 的凭证写在本次构建的临时 `DOCKER_CONFIG` 目录里，构建结束即删除，不污染 Jenkins 用户的 `~/.docker`。

### 4.5 Jenkins 的 RBAC 权限范围

`manifests/ci-deployer-rbac.yaml`，每个 `CI_NAMESPACES` 命名空间一个 Role：

- 可管理：Deployment / StatefulSet / DaemonSet / ReplicaSet（含 scale）、Service、ConfigMap、Secret、PVC、ServiceAccount、Job / CronJob、HPA、Ingress、PDB
- 只读：Pod、Pod 日志、Event、Endpoints
- 不可：其他命名空间、任何集群级资源（Node、Namespace、ClusterRole、CRD 等）

需要更多资源类型时改这个文件后重跑 `./scripts/60-ci-setup.sh`。

---

## 5. 运维

### 轮换

| 命令 | 作用 | 对 Jenkins 的影响 |
|---|---|---|
| `./scripts/60-ci-setup.sh rotate-key` | `accesskey`：新建一把密钥，**确认 Jenkins 已换成新的并跑通后**再删除旧的 | 无中断 |
| `./scripts/60-ci-setup.sh rotate-cert` | `rolesanywhere`：换发客户端证书 | 无中断；旧证书到期前仍有效 |
| `./scripts/60-ci-setup.sh rotate-token` | 吊销并重建 ServiceAccount token | **旧 kubeconfig 立即失效**，随即更新 `eks-kubeconfig` |
| `./scripts/60-ci-setup.sh kubeconfig` | 只重新生成 kubeconfig（集群端点或 CA 变了时） | 更新 `eks-kubeconfig` |

建议：访问密钥每 90 天 `rotate-key` 一次；证书到期前 `rotate-cert`（verify 会打印到期时间）。
ServiceAccount token 本身**不会过期**，人员变动或怀疑泄露时 `rotate-token`。

### 密钥 / 凭证泄露时

- **访问密钥**：立即停用 `aws iam update-access-key --user-name <PROJECT>-<ENV>-ci-ecr-push --access-key-id <AK> --status Inactive`，再 `rotate-key`。开启了 IP 锁定时，泄露的密钥在 Jenkins 出口以外本来就用不了。
- **kubeconfig**：`rotate-token`。
- **证书**：见下一节。

### 吊销证书

`rotate-cert` 不会让旧证书失效。需要立即作废所有已签发证书时，重建自建 CA：

```bash
rm -rf ~/.<PROJECT>-<ENV>-ci-pki        # 删除旧 CA（私钥也一并删除）
./scripts/60-ci-setup.sh                # 新 CA 替换 Trust Anchor 里的旧 CA，并签发新证书
# 然后用交接目录里新的 client.pem / client.key 更新 Jenkins 凭据 ecr-ra-cert / ecr-ra-key
```

Trust Anchor 更新后，旧 CA 签发的证书立即无法换取凭证。
紧急情况下也可以先停用整个入口：`aws rolesanywhere disable-trust-anchor --trust-anchor-id <id>`（恢复用 `enable-trust-anchor`）。
使用企业 PKI 时，按证书粒度吊销用 `aws rolesanywhere import-crl` 导入 CRL 并 `enable-crl`。

### 使用自有 CA

已有企业 PKI 时，不自建 CA，用企业 CA（或其下级 CA）签发 CN = `CI_CERT_CN` 的客户端证书：

```bash
CI_CA_CERT_FILE=/path/ca.pem \
CI_CLIENT_CERT_FILE=/path/jenkins.pem \
CI_CLIENT_KEY_FILE=/path/jenkins.key \
./scripts/60-ci-setup.sh
```

证书要求（Roles Anywhere）：X.509 v3；CA 证书 `basicConstraints CA:TRUE`、`keyUsage keyCertSign`；客户端证书为终端实体证书、SHA-256 及以上签名、RSA 或 EC 密钥，`keyUsage digitalSignature`。
使用自有 CA 时 `rotate-cert` 不可用，由企业 PKI 换发后更新上面三个变量重跑即可。

### Jenkins 出口 IP 变了

1. 改 `JENKINS_EGRESS_CIDRS`，重跑 `./scripts/60-ci-setup.sh`：更新密钥的来源 IP 限制，并把新 IP 追加进 EKS 白名单
2. 白名单只加不删；旧 IP 用 `./scripts/allow-my-ip.sh --list` 确认后，在 EKS 控制台「网络 → 管理端点访问」里删除，并同步 `config.env` 的 `API_PUBLIC_ACCESS_CIDRS`

### 切换认证方式

改 `CI_ECR_AUTH` 后重跑部署即可：`accesskey → rolesanywhere` 会先删除 IAM 用户的访问密钥，再换成 Roles Anywhere；反过来会删除角色 / Trust Anchor 并新建访问密钥。之后按新模式更新 Jenkins 凭据与 `CI_ECR_AUTH` 全局变量。

### 删除

```bash
./scripts/60-ci-setup.sh destroy
```

删除：各命名空间的 CI Role / RoleBinding、ServiceAccount 及其 token、访问密钥、栈 `<PROJECT>-<ENV>-ci-ecr`、交接目录。
保留：命名空间及其中的业务、ECR 仓库与镜像、CA 目录、EKS 白名单（需要时按上文手动删除）。
`99-destroy.sh` 不删除本扩展，残留检查里会提示。

---

## 6. 在 Jenkins 机器上自检

把交接目录拷到 Jenkins 机器（或 agent）上，用**与 Jenkins 相同的用户**执行，确认网络、凭证、权限都没问题后再配流水线。自检用的是交接目录里的文件，不会读取本机 `~/.aws`：

```bash
cd <交接目录>
export AWS_PROFILE=ci-ecr AWS_CONFIG_FILE=$PWD/aws-config AWS_EC2_METADATA_DISABLED=true KUBECONFIG=$PWD/kubeconfig
export AWS_SHARED_CREDENTIALS_FILE=$PWD/aws-credentials      # 仅 accesskey
# rolesanywhere：aws-config 里 credential_process 引用了 client.pem / client.key 的路径，
#   写的是 CloudShell 上的绝对路径，拷到 Jenkins 机器后先改成当前目录

curl -s https://checkip.amazonaws.com                         # 必须在 JENKINS_EGRESS_CIDRS 内
aws sts get-caller-identity                                   # user/...-ci-ecr-push 或 assumed-role/...-ci-ecr-push/...
source jenkins.env
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
aws ecr describe-images --region "$AWS_REGION" --repository-name "$ECR_REPO_PREFIX/demo-app" --query 'length(imageDetails)'   # 权限只到 <PROJECT>/*，不带仓库名的 describe-repositories 会被拒
aws s3 ls                                                     # 必须 AccessDenied（只有 ECR 权限）
kubectl -n app auth can-i patch deployments                   # yes
kubectl -n kube-system auth can-i get pods                    # no
docker logout "$ECR_REGISTRY"
```

---

## 7. 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `kubectl` 报 `dial tcp …:443: i/o timeout` | Jenkins 出口 IP 不在 EKS 公共端点白名单 | 确认 `curl checkip` 的结果在 `JENKINS_EGRESS_CIDRS` 内，重跑 `60-ci-setup.sh`；走代理时填代理的出口 IP |
| `kubectl` 报 `Unauthorized` | token 被 `rotate-token` 吊销了，或 kubeconfig 是旧集群的 | 用交接目录里最新的 `kubeconfig` 更新 `eks-kubeconfig` |
| `kubectl` 报 `forbidden … in the namespace "xxx"` | 命名空间不在 `CI_NAMESPACES` 里，或资源类型不在 Role 里 | 加进 `CI_NAMESPACES` 或改 `manifests/ci-deployer-rbac.yaml` 后重跑 |
| `ecr get-login-password` 报 `AccessDenied … explicit deny` | IP 锁定生效：请求不是从 `JENKINS_EGRESS_CIDRS` 发出的 | 核对出口 IP；Jenkins 出口 IP 不固定时设 `CI_KEY_LOCK_SOURCE_IP=false` 重跑 |
| `sts get-caller-identity` 成功但 ECR 被拒 | 同上。STS 身份查询不受 IAM 策略限制，所以能成功 | 同上 |
| `docker push` 报 `name unknown: The repository … does not exist` | 仓库没预建 | 加进 `CI_ECR_REPOSITORIES` 重跑（Jenkins 身份无权建仓库，这是刻意的） |
| `docker push` 报 `denied: … not authorized` | 仓库名不在 `<PROJECT>/` 前缀下 | 镜像名必须是 `$ECR_REGISTRY/$ECR_REPO_PREFIX/<名字>` |
| `aws_signing_helper` 报 `AccessDeniedException: Unable to assume role` | 证书 CN 不等于 `CI_CERT_CN`，或证书不是当前 Trust Anchor 里的 CA 签发的 | `openssl x509 -in client.pem -noout -subject -issuer` 核对；CA 重建过就用新证书 |
| `aws_signing_helper: command not found` | `rolesanywhere` 模式下 agent 没装 | 见 4.1 |
| Pod `ImagePullBackOff` / `exec format error` | 镜像架构与节点不一致 | `IMAGE_PLATFORM` 与节点一致；在 arm 机器上构建 amd64 需 buildx + QEMU |
| 新建任务的第一次构建参数为空 | Jenkins 在第一次运行时才登记 `parameters` | 示例 Jenkinsfile 已在 `environment` 里给了默认值，第二次起界面会出现参数 |
| 日志里 `WARNING! Your password will be stored unencrypted in …/config.json` | docker login 的通用提示 | 示例把它写在构建临时目录，构建结束即删除，可忽略 |

---

## 8. 其他可选方案（本包未实现）

- **Jenkins 所在环境支持 OIDC**（GitLab / GitHub Actions、自建 OIDC Provider）：用 IAM OIDC 身份提供商 + `AssumeRoleWithWebIdentity`，完全无长期凭证。
- **镜像先推客户自己的 Harbor**，再由 ECR 拉取缓存（Pull through cache）或复制：Jenkins 完全不接触 AWS 凭证。
- **GitOps（Argo CD / Flux 装在集群内）**：Jenkins 只推镜像并改 Git 里的镜像版本，集群自己拉取变更；Jenkins 不再需要 kubeconfig，EKS 白名单里也不用放 Jenkins 出口。

---

## 9. 实测记录（2026-09-28）

模拟 AWS 之外的 Jenkins：一台只有出站、**没有任何入站规则**的 EC2，Jenkins 只监听 `127.0.0.1:8080`，仅通过 SSM 端口转发访问。实例角色只有 SSM 权限，容器内访问不到 IMDS，所以 ECR / EKS 访问只能依赖交接目录里的凭证。

| 模式 | 结果 |
|---|---|
| `accesskey`（IP 锁定开启） | 身份 `user/…-ci-ecr-push`；推送 `demo-app:<build>` 成功；部署到 `app`，2 个 Pod Running，运行中的镜像版本校验通过；从非 Jenkins 出口（CloudShell）使用同一密钥登录 ECR 被拒 |
| `rolesanywhere` | 身份 `assumed-role/…-ci-ecr-push/<证书序列号>`；推送、部署、镜像版本校验均通过 |
| 两种模式 | `s3 list-buckets` 被拒；kubeconfig 不能操作 `kube-system`、不能读节点；日志中凭证被自动打码 |

---

## 10. 方式二：跳板机构建（Jenkins SSH 上传 JAR）

Jenkins 只负责接收 JAR 和 SSH；构建、推送都在跳板机上完成，ECR 权限来自跳板机实例角色。跳板机同时经 EKS 私有端点访问集群，运维人员可在上面直接 `kubectl`。

```
 Jenkins（任意位置，只需出站 22）
   │ ① 「Build with Parameters」上传 app.jar
   │ ② ssh ec2-user@<EIP>（密钥对 .pem，校验主机指纹）  上传 JAR
   ▼
 跳板机 m7i.large / x86_64 / 100 GiB（公有子网，EIP，22 只对白名单开放）
   │ ③ build-push-jar：生成 Dockerfile(eclipse-temurin JRE) → docker build --platform linux/amd64
   │ ④ 实例角色登录 ECR → push <账号>.dkr.ecr.<区域>.amazonaws.com/<PROJECT>/<app>:<构建号>
   │ ⑤ kubectl → EKS 私有端点（集群安全组放行跳板机安全组，Access Entry 集群管理员）
   ▼
 ECR  ──拉取──▶  EKS 节点
```

### 10.1 部署（在 CloudShell 执行，EKS 已存在即可，不改 EKS 栈）

```bash
./scripts/50-bastion.sh
```

交互式向导只问一件事：Jenkins 出口公网 IP（Jenkins 机器上 `curl -s https://checkip.amazonaws.com`）。SSH 密钥对由栈自动创建，私钥托管在 SSM Parameter Store，部署后保存到 CloudShell `~/.ssh/<PROJECT>-<ENV>-bastion-key.pem`，Jenkins 凭据用它。机型 m7i.large / 100 GiB / EIP / EKS 管理员权限都是默认值，回答写回 `config.env`，重跑不再询问。结束时自动验收并打印 Jenkins 配置（之后可用 `./scripts/50-bastion.sh jenkins` 再看）。

手把手步骤（含 Jenkins 逐项点击路径）见 **[bastion-upgrade.md](bastion-upgrade.md)**。

### 10.2 Jenkins 配置

| 项 | 位置 | 值 |
|---|---|---|
| 插件 | Manage Jenkins → Plugins | Pipeline、Credentials Binding、SSH Credentials、**File Parameters**（`stashedFile` 上传参数） |
| 凭据 | Manage Jenkins → Credentials → Global | 类型 **SSH Username with private key**；ID `bastion-ssh`；Username `ec2-user`；Private Key → Enter directly，粘贴 .pem 全部内容 |
| 全局环境变量 | Manage Jenkins → System → Global properties → Environment variables | `BASTION_HOST` = 跳板机 EIP；`BASTION_USER` = `ec2-user`；`BASTION_HOST_KEY` = `jenkins` 子命令打印的整行（`<EIP> ssh-ed25519 AAAA…`） |
| Jenkins 节点 | 执行构建的 agent | 只需要 `ssh` 客户端（不需要 scp / docker / aws CLI）和到 EIP:22 的出站 |

`BASTION_HOST_KEY` 用来校验跳板机身份（`StrictHostKeyChecking=yes`）。不填也能跑，但会降级为首次信任并在日志里告警。

### 10.3 流水线

新建 **Pipeline** Job，把 `ci/Jenkinsfile.bastion-jar.example` 粘贴到 Pipeline script（或放进代码仓库用 Pipeline script from SCM）。

1. 新 Job 先点一次「Build Now」：这次只注册参数，结果为 **NOT_BUILT**，描述为「首次运行：参数已注册」。
2. 之后点「**Build with Parameters**」：

| 参数 | 说明 |
|---|---|
| `APP_JAR` | 选择本地 JAR 上传（需可 `java -jar` 启动，如 Spring Boot fat jar） |
| `APP_NAME` | ECR 仓库名，实际为 `<PROJECT>/<APP_NAME>`，不存在自动创建（推送时漏洞扫描） |
| `IMAGE_TAG` | 留空 = 构建号 |
| `JAVA_VERSION` | 17 / 21 / 11 / 8，对应 `eclipse-temurin:<ver>-jre` 基础镜像 |
| `APP_PORT` / `JAVA_OPTS` | 写进镜像的 EXPOSE 与默认 JAVA_OPTS（运行时可用环境变量覆盖） |
| `PUSH_LATEST` | 同时推 `latest` |

流水线步骤：取 JAR（上传的优先，否则取工作区里的 `*.jar`）→ SSH 上传到跳板机 `~/builds/<job>-<构建号>/` → 跳板机执行 `build-push-jar` → 解析 `IMAGE_URI` / `IMAGE_DIGEST` 写进构建描述并归档 `image.txt` → 删除跳板机临时目录和 Jenkins 上的私钥副本。

需要自定义镜像（加字体、agent、改启动命令）时，在工作区根目录放一个 `Dockerfile`，它会连同 JAR（名为 `app.jar`）一起上传使用。想从源码开始，在「获取 JAR」前加一个 `git` + `mvn package` 阶段即可，后面会自动取到产物。

跳板机上也可以手工构建：

```bash
build-push-jar --jar ./order-service.jar --app order-service --tag 1.0.0 --java 17
build-push-jar --help
```

### 10.4 部署到 EKS

镜像推完后在跳板机上（`./scripts/50-bastion.sh ssm` 或 SSH）直接用 kubectl，kubeconfig 已配好：

```bash
kubectl -n app set image deploy/order-service order-service=<IMAGE_URI>
kubectl -n app rollout status deploy/order-service
```

若也要由 Jenkins 自动发布，可在流水线末尾追加一步 `"$BSSH" "kubectl -n app set image …"`（跳板机是集群管理员，生产环境建议 `BASTION_EKS_ACCESS=none` 并单独建命名空间级权限），或结合方式一的受限 kubeconfig。

### 10.5 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `ssh: connect to host … port 22: Connection timed out` | Jenkins 出口不在白名单 | 把出口 IP 填进 `JENKINS_EGRESS_CIDRS` 后重跑 `./scripts/50-bastion.sh` |
| `Host key verification failed` | 跳板机被替换，主机密钥变了 | 重跑 `./scripts/50-bastion.sh jenkins`，更新 `BASTION_HOST_KEY` |
| `Permission denied (publickey)` | 凭据私钥不是 `~/.ssh/<PROJECT>-<ENV>-bastion-key.pem`（跳板机重建后私钥会变），或 Username 不是 `ec2-user` | 核对凭据 `bastion-ssh` |
| 首次构建之外仍提示「没有 JAR」 | 没用 Build with Parameters，或缺 File Parameters 插件 | 装插件，用带参数构建上传 |
| `MANIFEST 里没有 Main-Class` | 上传的是 plain jar（如 Spring Boot 的 `*-plain.jar`） | 上传 repackage 后的 fat jar，或自带 Dockerfile |
| `docker push` 报 `denied` | 仓库不在 `<PROJECT>/` 前缀下 | `APP_NAME` 不要带前缀，工具会自动加 |
| 跳板机上 kubectl 超时 | 集群关闭了私有端点 | `./scripts/50-bastion.sh verify` 会给出原因 |

### 10.6 实测记录（2026-09-28）

测试 Jenkins 与 9 节相同（AWS 之外的模拟环境，只出站），跳板机 m7i.large / x86_64 / 100 GiB，`BASTION_HOST_KEY` 严格校验：

| 项 | 结果 |
|---|---|
| `verify` | docker 25.0.16 + buildx v0.19.3；ECR 登录成功；kubectl v1.36.5，API 解析到私有 IP，2 个节点 Ready，`can-i create deployments` = yes；节点 10250 可达；S3 可列桶 |
| `test-build` | 机上编译 Hello.java → `sharetronic/smoke-test:<tag>` 推送成功 → EKS 中 Pod 返回 `hello from jar, java 17.0.20.1, arch amd64` |
| Jenkins 首次构建 | NOT_BUILT，参数注册成功 |
| Jenkins 上传 22 MB Spring Boot 3 JAR | SUCCESS，推送 `sharetronic/order-service:<构建号>`，构建描述带 digest；跳板机临时目录与 Jenkins 私钥副本均已清理 |
| 在跳板机用 kubectl 部署该镜像 | Pod Running，`/` 返回 `order-service ok, java 17.0.20.1, arch amd64`，`/actuator/health` = `UP` |

