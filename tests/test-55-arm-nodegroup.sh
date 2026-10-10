#!/usr/bin/env bash
# =============================================================================
#  55-arm-nodegroup 离线测试：不访问 AWS / 集群（aws、curl 用 stub 替身）
#    - 静态：bash -n、cfn-lint（已安装时）、模板关键安全/架构约束
#    - 单元：节点数校验、desired 夹取、CAS 模板标签、命名校验、子网解析、机型架构/AZ 供给检查
#    - 生成的集群内测试脚本：三种模式语法正确、参数经 %q 转义
#  用法：./tests/test-55-arm-nodegroup.sh
#  线上端到端验收见 ./scripts/55-arm-nodegroup.sh verify / test-scale
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/55-arm-nodegroup.sh"
TEMPLATE="${ROOT}/cloudformation/55-eks-nodegroup-arm64.yaml"
STUB="$(mktemp -d)"; trap 'rm -rf "${STUB}"' EXIT
PASS=0 FAIL=0

t()  { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }
tn() { t "$1" "! ( $2 )"; }   # 期望失败
# 在子 shell 里 source 被测脚本（只加载函数，不执行子命令），再执行给定语句
run() { ( export PATH="${STUB}:${PATH}"; source "${SCRIPT}"; eval "$1" ); }

# ---------------------------------------------------------------- stub
cat > "${STUB}/curl" <<'EOF'
#!/usr/bin/env bash
echo 203.0.113.10
EOF
# aws stub：按参数返回固定数据。多值输出与真实 CLI 一致，用 TAB 分隔（--output text）
# 写操作记到 ${STUB}/calls，现有 ASG 标签从 ${STUB}/asg-tags 读
cat > "${STUB}/aws" <<'EOF'
#!/usr/bin/env bash
a="$*"; d="$(dirname "$0")"
case "${a}" in
  *"eks describe-nodegroup"*"ng-general"*"nodegroup.subnets"*) printf 'subnet-a\tsubnet-b\n' ;;
  *"eks describe-nodegroup"*"autoScalingGroups"*)              echo asg-1 ;;
  *"ec2 describe-subnets"*)                                    printf 'az-a\taz-b\n' ;;
  *"describe-instance-types"*"m8g.large"*|*"describe-instance-types"*"c8g.large"*) echo arm64 ;;
  *"describe-instance-types"*"m7i.large"*)                     echo x86_64 ;;
  *"describe-instance-type-offerings"*"c8g.large"*)            echo "az-a" ;;
  *"describe-instance-type-offerings"*)                        printf 'az-a\taz-b\n' ;;
  *"autoscaling describe-tags"*)                               paste -sd$'\t' "${d}/asg-tags" ;;
  *"autoscaling create-or-update-tags"*|*"autoscaling delete-tags"*) echo "${a}" >> "${d}/calls" ;;
  *) echo "unexpected aws call: ${a}" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB}/curl" "${STUB}/aws"

echo "静态检查"
t "脚本语法 bash -n"            "bash -n '${SCRIPT}'"
t "lib.sh / 50-bastion 语法"   "bash -n '${ROOT}/scripts/lib.sh' && bash -n '${ROOT}/scripts/50-bastion.sh' && bash -n '${ROOT}/scripts/99-destroy.sh'"
if command -v cfn-lint >/dev/null 2>&1; then
  t "cfn-lint 模板"             "cfn-lint '${TEMPLATE}'"
else
  echo "  skip cfn-lint 未安装"
fi
# 模板约束：用能识别 CFN 短语法（!Ref 等）的 loader 解析
t "模板约束（仅 ARM AMI / IMDSv2 / 加密卷 / 条件 taint / Graviton 默认机型）" "python3 - '${TEMPLATE}' <<'PY'
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l, s, n: {s: l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else (l.construct_mapping(n) if isinstance(n, yaml.MappingNode) else l.construct_scalar(n))})
d = yaml.load(open(sys.argv[1]), Loader=L)
p, r = d['Parameters'], d['Resources']
assert p['AmiType']['AllowedValues'] == ['AL2023_ARM_64_STANDARD']
assert all(t.split('.')[0].endswith(('g', 'gd', 'gn')) for t in p['InstanceTypes']['Default'].split(','))
lt = r['NodeLaunchTemplate']['Properties']['LaunchTemplateData']
assert lt['MetadataOptions']['HttpTokens'] == 'required'
assert lt['BlockDeviceMappings'][0]['Ebs']['Encrypted'] is True
ng = r['NodeGroup']['Properties']
assert ng['Taints']['If'][0] == 'UseArchTaint'
assert ng['Taints']['If'][1][0]['Effect'] == 'NO_SCHEDULE'
assert ng['Labels']['role'] == 'arm64'
assert int(p['MinSize']['Default']) == 0
PY"

echo "validate_sizes"
t  "0/1/4 合法"                 "run 'validate_sizes 0 1 4'"
t  "4/4/4 合法"                 "run 'validate_sizes 4 4 4'"
tn "min > desired"              "run 'validate_sizes 2 1 4'"
tn "desired > max"              "run 'validate_sizes 0 5 4'"
tn "max = 0"                    "run 'validate_sizes 0 0 0'"
tn "非数字"                     "run 'validate_sizes a 1 2'"

echo "clamp_desired"
t "节点组不存在时用配置值"      "[[ \$(run 'clamp_desired \"\" 1 0 4') == 1 ]]"
t "沿用 CAS 调整后的值"         "[[ \$(run 'clamp_desired 3 1 0 4') == 3 ]]"
t "超过 max 时夹到 max"         "[[ \$(run 'clamp_desired 9 1 0 4') == 4 ]]"
t "低于新 min 时夹到 min"       "[[ \$(run 'clamp_desired 0 1 2 4') == 2 ]]"

echo "cas_template_tags"
t "taint 开启：4 个标签含 taint" "[[ \$(run 'cas_template_tags ng-arm64 true arch arm64' | wc -l) == 4 ]] && run 'cas_template_tags ng-arm64 true arch arm64' | grep -qx 'k8s.io/cluster-autoscaler/node-template/taint/arch=arm64:NoSchedule'"
t "nodegroup 标签用于 nodeSelector 从 0 扩容" "run 'cas_template_tags ng-arm64 true arch arm64' | grep -qx 'k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/nodegroup=ng-arm64'"
t "taint 关闭：无 taint 标签"   "[[ \$(run 'cas_template_tags ng-arm64 false arch arm64' | grep -c /taint/) == 0 ]]"

echo "validate_names"
t  "默认配置合法"               "run 'validate_names'"
tn "与 x86 节点组同名"          "run 'ARM_NODEGROUP_NAME=\$NODEGROUP_NAME; validate_names'"
tn "节点组名含 shell 元字符"    "run 'ARM_NODEGROUP_NAME=\"ng;rm\"; validate_names'"
tn "非法 capacity type"         "run 'ARM_NODE_CAPACITY_TYPE=RESERVED; validate_names'"
tn "非法 taint value"           "run 'ARM_TAINT_VALUE=\"a b\"; validate_names'"
tn "非法 ARM_KUBE_VIA"          "run 'ARM_KUBE_VIA=ssh; validate_names'"
tn "子网 ID 不合法（防 CLI 选项注入）" "run 'ARM_NODE_SUBNET_IDS=\"--endpoint-url=http://x\"; validate_names'"
t  "子网 ID 列表合法"            "run 'ARM_NODE_SUBNET_IDS=\"subnet-0a1b, subnet-0c2d\"; validate_names'"
tn "max 非整数"                  "run 'ARM_NODE_MAX_SIZE=\"a[\\\$(id)]\"; validate_names'"
tn "机型列表为空"                "run 'ARM_NODE_INSTANCE_TYPES=\" , \"; validate_names'"
tn "非法机型格式"               "run 'ARM_NODE_INSTANCE_TYPES=\"m8g.large,\\\$(id)\"; validate_names'"

echo "resolve_subnets"
t "默认复用 x86 节点组子网"     "[[ \$(run 'resolve_subnets') == subnet-a,subnet-b ]]"
t "显式配置优先"                "[[ \$(run 'ARM_NODE_SUBNET_IDS=\"subnet-x, subnet-y\"; resolve_subnets') == subnet-x,subnet-y ]]"

echo "check_instance_types"
t  "Graviton 机型全 AZ 有供给"  "run 'check_instance_types m8g.large subnet-a,subnet-b'"
tn "x86 机型被拒绝"             "run 'check_instance_types m8g.large,m7i.large subnet-a,subnet-b'"
tn "某个 AZ 无供给被拒绝"       "run 'check_instance_types c8g.large subnet-a,subnet-b'"

echo "tag_asg_for_cas"
P=k8s.io/cluster-autoscaler/node-template
printf '%s\n' "${P}/taint/arch" "${P}/label/role" "k8s.io/cluster-autoscaler/enabled" > "${STUB}/asg-tags"
: > "${STUB}/calls"
t "taint key 改名后删除旧 taint 标签"  "run 'ARM_TAINT_KEY=workload; tag_asg_for_cas' && grep -q 'delete-tags.*Key=${P}/taint/arch' '${STUB}/calls'"
t "写入新 taint 标签"                  "grep -q 'Key=${P}/taint/workload,Value=arm64:NoSchedule' '${STUB}/calls'"
t "不删期望内标签与非模板标签"         "! grep -qE 'delete-tags.*Key=(${P}/label/role|k8s.io/cluster-autoscaler/enabled)' '${STUB}/calls'"
: > "${STUB}/calls"
t "关闭 taint 后删除 taint 标签"       "run 'ARM_NODE_TAINT=false; tag_asg_for_cas' && grep -q 'delete-tags.*Key=${P}/taint/arch' '${STUB}/calls' && ! grep -q 'create-or-update-tags.*/taint/' '${STUB}/calls'"

echo "render_k8s_script"
for m in verify scale workloads; do
  t "${m} 模式脚本语法正确"     "run 'f=\$(mktemp); render_k8s_script ${m} \$f; bash -n \$f; rc=\$?; rm -f \$f; exit \$rc'"
done
t "参数经 %q 转义"              "run 'f=\$(mktemp); ARM_NODEGROUP_NAME=\"a b\"; render_k8s_script verify \$f; grep -q \"NG=a\\\\\\\\ b \" \$f; rc=\$?; rm -f \$f; exit \$rc'"
t "测试 namespace 有归属保护与 PSA restricted" "run 'f=\$(mktemp); render_k8s_script verify \$f; grep -q \"managed-by: 55-arm-nodegroup\" \$f && grep -q \"enforce=restricted\" \$f && grep -q seccompProfile \$f; rc=\$?; rm -f \$f; exit \$rc'"
t "taint 关闭时不生成容忍"      "run 'f=\$(mktemp); ARM_NODE_TAINT=false; render_k8s_script verify \$f; grep -q \"TAINT=false\" \$f; rc=\$?; rm -f \$f; exit \$rc'"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
(( FAIL == 0 ))
