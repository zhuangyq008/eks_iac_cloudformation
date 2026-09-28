#!/usr/bin/env bash
# =============================================================================
#  02-deploy.sh —— 按序部署全部 CloudFormation 栈
#
#  幂等：任何一步失败或 CloudShell 断连，直接重跑本脚本即可续上
#  （已完成的栈会走"无变更"路径，进行中的栈会先等它结束）。
#
#  用法：
#    ./scripts/02-deploy.sh              # 全量部署（交互确认）
#    ASSUME_YES=1 ./scripts/02-deploy.sh # 跳过确认
#    ./scripts/02-deploy.sh network      # 只跑指定阶段
#    阶段名: network | cluster | nodegroup | addons | nacos
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

network_config_ok || die "config.env 的 VPC / 子网在账号 $(account_id) / ${AWS_REGION} 中无效。先执行 ./scripts/01-preflight.sh（会引导选择 VPC 与子网）"

ONLY="${1:-all}"
want() { [[ "${ONLY}" == "all" || "${ONLY}" == "$1" ]]; }

# Nacos 是可选组件。INSTALL_NACOS=false 时在 all 模式下跳过阶段 5；
# 但显式 `02-deploy.sh nacos` 视为明确意图，仍然部署。
want_nacos() {
  if [[ "${ONLY}" == "nacos" ]]; then
    [[ "${INSTALL_NACOS}" == "true" ]] || warn "显式指定 nacos 阶段，忽略 INSTALL_NACOS=${INSTALL_NACOS}"
    return 0
  fi
  [[ "${ONLY}" == "all" && "${INSTALL_NACOS}" == "true" ]]
}
TOTAL_STAGES=5
[[ "${INSTALL_NACOS}" == "true" ]] || TOTAL_STAGES=4

START_TS=$(date +%s)
section "部署计划"
cat <<EOF
  Region        : ${AWS_REGION}
  Account       : $(account_id)
  VPC           : ${VPC_ID}
  公有子网      : ${PUBLIC_SUBNET_IDS}
  私有子网      : ${PRIVATE_SUBNET_IDS}
  EKS           : ${CLUSTER_NAME}  (K8s ${K8S_VERSION})
  API 白名单    : ${API_PUBLIC_ACCESS_CIDRS}
  节点组        : ${NODEGROUP_NAME}  ${NODE_INSTANCE_TYPES}  ${NODE_CAPACITY_TYPE}  ${NODE_MIN_SIZE}/${NODE_DESIRED_SIZE}/${NODE_MAX_SIZE}
  Nacos         : $( [[ "${INSTALL_NACOS}" == "true" ]] \
                      && echo "${NACOS_VERSION} on ${NACOS_INSTANCE_TYPE} + RDS MySQL ${NACOS_DB_ENGINE_VERSION} (${NACOS_DB_INSTANCE_CLASS})" \
                      || echo "跳过（INSTALL_NACOS=false）" )
  NAT 策略      : ${CREATE_NAT_GATEWAY}
  预计耗时      : $( [[ "${INSTALL_NACOS}" == "true" ]] && echo "25-35 分钟（EKS 控制面 ~10min，RDS ~10min）" || echo "15-20 分钟（不含 Nacos）" )
EOF
confirm "开始部署？" || die "已取消"

# =============================================================================
#  阶段 1 —— 网络前置：私有子网出网 + 子网 k8s 标签
# =============================================================================
if want network; then
  section "阶段 1/${TOTAL_STAGES}  网络前置"

  # ---- 1a. VPC DNS 属性 ----
  # 必须在建集群之前修好：属性为 false 时节点会把集群端点解析成公网 IP，
  # 走 NAT 访问公共端点又被 CIDR 白名单挡住，结果节点永远注册不上，
  # 且 describe-nodegroup 的 health.issues 是空的，排查方向会被完全带偏。
  log "检查 VPC DNS 属性"
  case "${FIX_VPC_DNS:-auto}" in
    auto|true) ensure_vpc_dns_attributes fix || die "VPC DNS 属性修复失败" ;;
    *)         ensure_vpc_dns_attributes check || die "VPC DNS 属性不满足 EKS 要求，且 FIX_VPC_DNS=${FIX_VPC_DNS}" ;;
  esac

  # ---- 1b. 私有子网出网 ----
  analyze_private_egress no
  printf '  私有路由表: %s\n' "${PRIVATE_RTBS}"

  DO_NAT=0
  case "${CREATE_NAT_GATEWAY}" in
    true) DO_NAT=1 ;;
    auto) (( NEED_NAT == 1 )) && DO_NAT=1 ;;
    false)
      if (( NEED_NAT == 1 )); then
        die "私有子网无法出网且 CREATE_NAT_GATEWAY=false。请先修好出网路径，否则节点无法拉取 ECR 镜像、Nacos 无法下载安装包"
      fi
      ;;
  esac

  if (( DO_NAT == 1 )); then
    NAT_SUBNET="$(pick_nat_public_subnet)" \
      || die "找不到默认路由指向 IGW 的公有子网，无法放置 NAT 网关（检查 PUBLIC_SUBNET_IDS）"
    log "将在公有子网 ${NAT_SUBNET} 创建 NAT 网关"

    # 残留 blackhole 路由会让 CFN 报 RouteAlreadyExists，先清掉
    analyze_private_egress yes

    # 需要补路由的表；如果 CREATE_NAT_GATEWAY=true 但路由本来就正常，则不动它
    RTBS="${RTBS_NEED_ROUTE}"
    if [[ -z "${RTBS}" ]]; then
      warn "所有私有路由表默认路由都正常，跳过 NAT 栈"
    else
      # 允许 config.env 显式指定；否则用自动发现的结果
      if [[ -n "${PRIVATE_ROUTE_TABLE_IDS}" ]]; then
        RTBS="${PRIVATE_ROUTE_TABLE_IDS//,/ }"
        log "使用 config.env 指定的路由表: ${RTBS}"
      fi
      set -- ${RTBS}
      (( $# <= 3 )) || die "需要补路由的私有路由表有 $# 个，模板最多支持 3 个，请扩展 05-network-prereq.yaml"
      RT1="${1}"; RT2="${2:-}"; RT3="${3:-}"

      deploy_stack "${STACK_NETWORK}" "${CFN_DIR}/05-network-prereq.yaml" \
        "ProjectName=${PROJECT}" \
        "EnvironmentName=${ENVIRONMENT}" \
        "VpcId=${VPC_ID}" \
        "NatGatewaySubnetId=${NAT_SUBNET}" \
        "PrivateRouteTableId1=${RT1}" \
        "PrivateRouteTableId2=${RT2}" \
        "PrivateRouteTableId3=${RT3}"

      NAT_EIP="$(stack_output "${STACK_NETWORK}" NatEipAddress)"
      ok "NAT 网关就绪，私有子网出网源 IP = ${NAT_EIP}（可给对端做白名单）"

      log "复核私有子网出网路由"
      analyze_private_egress no
      (( NEED_NAT == 0 )) || die "NAT 创建后路由仍不正常，请人工检查 ${PRIVATE_RTBS}"
    fi
  else
    ok "私有子网已具备出网能力，不创建 NAT 网关"
  fi

  log "给子网打 Kubernetes 发现标签（ALB/NLB 自动发现依赖）"
  tag_subnets_for_k8s
fi

# =============================================================================
#  阶段 2 —— EKS 控制面
# =============================================================================
if want cluster; then
  section "阶段 2/${TOTAL_STAGES}  EKS 控制面（约 10 分钟）"
  deploy_stack "${STACK_CLUSTER}" "${CFN_DIR}/10-eks-cluster.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "ClusterName=${CLUSTER_NAME}" \
    "KubernetesVersion=${K8S_VERSION}" \
    "VpcId=${VPC_ID}" \
    "ClusterSubnetIds=${PRIVATE_SUBNET_IDS}" \
    "ServiceIpv4Cidr=${SERVICE_IPV4_CIDR}" \
    "PublicAccessCidrs=${API_PUBLIC_ACCESS_CIDRS}" \
    "AdminPrincipalArn=${ADMIN_PRINCIPAL_ARN}" \
    "EnableSecretsEncryption=${ENABLE_SECRETS_ENCRYPTION}"

  CLUSTER_SG="$(stack_output "${STACK_CLUSTER}" ClusterSecurityGroupId)"
  printf '  集群端点   : %s\n' "$(stack_output "${STACK_CLUSTER}" ClusterEndpoint)"
  printf '  集群安全组 : %s\n' "${CLUSTER_SG}"
  printf '  OIDC       : %s\n' "$(stack_output "${STACK_CLUSTER}" ClusterOidcIssuerUrl)"
fi

# =============================================================================
#  阶段 3 —— 托管节点组
# =============================================================================
if want nodegroup; then
  section "阶段 3/${TOTAL_STAGES}  托管节点组（约 5 分钟）"
  deploy_stack "${STACK_NODEGROUP}" "${CFN_DIR}/20-eks-nodegroup.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "ClusterName=${CLUSTER_NAME}" \
    "NodeGroupName=${NODEGROUP_NAME}" \
    "NodeSubnetIds=${PRIVATE_SUBNET_IDS}" \
    "AmiType=${NODE_AMI_TYPE}" \
    "InstanceTypes=${NODE_INSTANCE_TYPES}" \
    "CapacityType=${NODE_CAPACITY_TYPE}" \
    "DesiredSize=${NODE_DESIRED_SIZE}" \
    "MinSize=${NODE_MIN_SIZE}" \
    "MaxSize=${NODE_MAX_SIZE}" \
    "VolumeSize=${NODE_VOLUME_SIZE}" \
    "SshKeyName="
fi

# =============================================================================
#  阶段 4 —— Addon + 控制器 IAM
# =============================================================================
if want addons; then
  section "阶段 4/${TOTAL_STAGES}  托管 Addon 与控制器 IAM（约 5 分钟）"

  LB_POLICY_ARN=""
  if [[ "${INSTALL_LB_CONTROLLER}" == "true" ]]; then
    log "准备 AWS Load Balancer Controller 的 IAM 策略（策略文件已随仓库固化）"
    LB_POLICY_ARN="$(ensure_lb_controller_policy)"
    ok "策略 ARN: ${LB_POLICY_ARN}"
  fi

  deploy_stack "${STACK_ADDONS}" "${CFN_DIR}/30-eks-addons.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "ClusterName=${CLUSTER_NAME}" \
    "EnablePrefixDelegation=false" \
    "LbControllerPolicyArn=${LB_POLICY_ARN}" \
    "EnableClusterAutoscalerRole=${INSTALL_CLUSTER_AUTOSCALER}"
fi

# =============================================================================
#  阶段 5 —— Nacos
# =============================================================================
if want_nacos; then
  section "阶段 5/${TOTAL_STAGES}  Nacos + RDS MySQL（约 12 分钟，RDS 创建最慢）"

  CLUSTER_SG="$(stack_output "${STACK_CLUSTER}" ClusterSecurityGroupId)"
  [[ -n "${CLUSTER_SG}" && "${CLUSTER_SG}" != "None" ]] \
    || die "取不到 EKS 集群安全组，请先完成 cluster 阶段"

  NACOS_ARCH="$(instance_type_arch "${NACOS_INSTANCE_TYPE}")"
  NACOS_AMI="$(resolve_al2023_ami "${NACOS_ARCH}")"
  ok "Nacos AMI (${NACOS_ARCH}): ${NACOS_AMI}"

  deploy_stack "${STACK_NACOS}" "${CFN_DIR}/40-nacos.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "VpcId=${VPC_ID}" \
    "PrivateSubnetIds=${PRIVATE_SUBNET_IDS}" \
    "EksClusterSecurityGroupId=${CLUSTER_SG}" \
    "ExtraClientCidrs=${NACOS_EXTRA_CLIENT_CIDRS}" \
    "InstanceType=${NACOS_INSTANCE_TYPE}" \
    "AmiId=${NACOS_AMI}" \
    "NacosVersion=${NACOS_VERSION}" \
    "NacosDownloadBaseUrl=${NACOS_DOWNLOAD_BASE_URL}" \
    "JvmXmx=${NACOS_JVM_XMX}" \
    "RootVolumeSize=${NACOS_ROOT_VOLUME_SIZE}" \
    "SshKeyName=${NACOS_KEY_NAME}" \
    "EnableCloudWatchLogs=${NACOS_ENABLE_CLOUDWATCH_LOGS}" \
    "DbInstanceClass=${NACOS_DB_INSTANCE_CLASS}" \
    "DbEngineVersion=${NACOS_DB_ENGINE_VERSION}" \
    "DbParameterGroupFamily=${NACOS_DB_PARAMETER_GROUP_FAMILY}" \
    "DbAllocatedStorage=${NACOS_DB_ALLOCATED_STORAGE}" \
    "DbMultiAZ=${NACOS_DB_MULTI_AZ}" \
    "DbBackupRetention=${NACOS_DB_BACKUP_RETENTION}" \
    "DbDeletionProtection=${NACOS_DB_DELETION_PROTECTION}"

  # 栈 CREATE_COMPLETE 只代表 AWS 资源建好了，不代表 Nacos 进程已就绪。
  # 真正的就绪信号是目标组健康检查通过。
  TG_ARN="$(stack_output "${STACK_NACOS}" TargetGroupHttpArn)"
  log "等待 Nacos 通过 NLB 健康检查（首次启动含下载/建库/建表，最长 ~12 分钟）"
  HEALTHY=0
  for i in $(seq 1 72); do
    STATE=$(aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "none")
    if [[ "${STATE}" == "healthy" ]]; then HEALTHY=1; ok "Nacos 目标健康"; break; fi
    printf '\r  [%02d/72] 目标状态: %-12s' "${i}" "${STATE}"
    sleep 10
  done
  echo
  if (( HEALTHY == 0 )); then
    warn "Nacos 尚未通过健康检查。排查方式："
    INST=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$(stack_output "${STACK_NACOS}" AutoScalingGroupName)" \
            --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "?")
    cat <<EOF
    aws ssm start-session --region ${AWS_REGION} --target ${INST}
      sudo tail -100 /var/log/nacos-bootstrap.log
      sudo journalctl -u nacos -n 100 --no-pager
    CloudWatch 日志组: /${PROJECT}/${ENVIRONMENT}/nacos
EOF
  fi
fi

# =============================================================================
#  汇总
# =============================================================================
section "部署汇总"
ELAPSED=$(( $(date +%s) - START_TS ))
printf '  耗时: %d 分 %d 秒\n\n' $((ELAPSED/60)) $((ELAPSED%60))

for s in "${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_ADDONS}" "${STACK_NACOS}"; do
  printf '  %-46s %s\n' "$s" "$(stack_status "$s")"
done
echo
printf '  集群端点       : %s\n' "$(stack_output "${STACK_CLUSTER}" ClusterEndpoint)"
printf '  集群安全组     : %s\n' "$(stack_output "${STACK_CLUSTER}" ClusterSecurityGroupId)"
if [[ "$(stack_status "${STACK_NACOS}")" == *COMPLETE ]]; then
  printf '  Nacos server-addr : %s\n' "$(stack_output "${STACK_NACOS}" NacosServerAddr)"
  printf '  Nacos 控制台      : %s\n' "$(stack_output "${STACK_NACOS}" NacosConsoleUrl)"
  printf '  Nacos RDS         : %s\n' "$(stack_output "${STACK_NACOS}" DbEndpoint)"
else
  printf '  Nacos             : 未部署（INSTALL_NACOS=%s）\n' "${INSTALL_NACOS}"
fi
echo
hr
cat <<EOF
  下一步：

    export PATH="\$HOME/.local/bin:\$PATH"     # CloudShell 里让 kubectl/helm 生效
    ./scripts/03-post-install.sh              # 装 ALB Controller / Cluster Autoscaler / gp3 默认 SC
    ./scripts/04-verify.sh                    # 端到端验证
EOF
