#!/usr/bin/env bash
# =============================================================================
#  configure-network.sh —— 交互式网络配置向导
#
#  确认区域 -> 选择 VPC -> 列出子网（自动识别公有/私有并给出建议）-> 选择 -> 校验 -> 写回 config.env
#  01-preflight.sh 发现 config.env 的网络配置在当前账号无效（例如仍是随包示例值）时会自动调用。
#
#  用法：
#    ./scripts/configure-network.sh                          # 交互：从列表选 VPC
#    ./scripts/configure-network.sh vpc-xxxxxxxx             # 直接指定 VPC
#    ASSUME_YES=1 ./scripts/configure-network.sh vpc-xxxx    # 无人值守：子网与网段全部采用建议值
#
#  写入的变量：AWS_REGION / VPC_ID / PUBLIC_SUBNET_IDS / PRIVATE_SUBNET_IDS /
#             PRIVATE_ROUTE_TABLE_IDS / NACOS_EXTRA_CLIENT_CIDRS / SERVICE_IPV4_CIDR / BASTION_SUBNET_ID
#  原文件备份为 config.env.bak。
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG="${ROOT_DIR}/config.env"
ORIG_REGION="${AWS_REGION}"
ARG_VPC="${1:-}"
VPCS_JSON="${OUT_DIR}/cfg-vpcs.json"
SUBNETS_TSV="${OUT_DIR}/cfg-subnets.tsv"

ask() {
  # ask "提示" "默认值" —— 提示写 stderr，答案写 stdout；ASSUME_YES=1 时直接取默认值
  local p="$1" d="${2:-}" a
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then echo "${d}"; return; fi
  read -r -p "  ${p}${d:+ [回车 = ${d}]}: " a
  echo "${a:-${d}}"
}

retry_or_die() {
  # 交互模式下校验失败可以重选；无人值守直接失败
  [[ "${ASSUME_YES:-0}" == "1" ]] && die "建议值未通过校验，请交互运行本脚本或手工编辑 config.env"
  return 0
}

# =============================================================================
section "1/5 账号与区域"
printf '  Account : %s\n' "$(account_id)"
printf '  Caller  : %s\n' "$(caller_arn)"
while :; do
  REGION="$(ask "部署区域" "${AWS_REGION}")"
  if aws ec2 describe-regions --region "${REGION}" --region-names "${REGION}" >/dev/null 2>&1; then
    break
  fi
  err "区域 ${REGION} 不存在或当前账号未启用"; retry_or_die
done
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
ok "区域 ${AWS_REGION}"

# =============================================================================
section "2/5 选择 VPC"
aws ec2 describe-vpcs --output json > "${VPCS_JSON}"
python3 - "${VPCS_JSON}" <<'PY'
import json, sys
vpcs = sorted(json.load(open(sys.argv[1]))["Vpcs"], key=lambda v: v["VpcId"])
if not vpcs:
    sys.exit("  （该区域没有 VPC）")
print("  %-3s %-22s %-34s %-8s %s" % ("#", "VPC", "CIDR", "DEFAULT", "NAME"))
for i, v in enumerate(vpcs, 1):
    cidrs = ",".join(a["CidrBlock"] for a in v.get("CidrBlockAssociationSet", [])
                     if a["CidrBlockState"]["State"] == "associated")
    name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "")
    print("  %-3s %-22s %-34s %-8s %s" % (i, v["VpcId"], cidrs, "yes" if v.get("IsDefault") else "", name))
PY
read -r -a VPC_IDS <<< "$(python3 -c 'import json,sys; print(" ".join(sorted(v["VpcId"] for v in json.load(open(sys.argv[1]))["Vpcs"])))' "${VPCS_JSON}")"
(( ${#VPC_IDS[@]} > 0 )) || die "区域 ${AWS_REGION} 没有 VPC。本交付包不创建 VPC，请先建好 VPC 与子网"

DEFAULT_VPC="${ARG_VPC}"
if [[ -z "${DEFAULT_VPC}" ]] && printf '%s\n' "${VPC_IDS[@]}" | grep -qx "${VPC_ID:-none}"; then
  DEFAULT_VPC="${VPC_ID}"
fi
[[ -z "${DEFAULT_VPC}" && ${#VPC_IDS[@]} -eq 1 ]] && DEFAULT_VPC="${VPC_IDS[0]}"
[[ "${ASSUME_YES:-0}" == "1" && -z "${DEFAULT_VPC}" ]] && die "无人值守模式请传入 VPC ID：$0 vpc-xxxx"

while :; do
  pick="$(ask "输入编号或 VPC ID" "${DEFAULT_VPC}")"
  if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#VPC_IDS[@]} )); then
    NEW_VPC="${VPC_IDS[pick-1]}"; break
  elif printf '%s\n' "${VPC_IDS[@]}" | grep -qx "${pick}"; then
    NEW_VPC="${pick}"; break
  fi
  err "无效选择：${pick:-（空）}"; retry_or_die
done
ok "VPC ${NEW_VPC}"

# =============================================================================
section "3/5 选择子网"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=${NEW_VPC}" --output json > "${OUT_DIR}/cfg-subnets.json"
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${NEW_VPC}" --output json > "${OUT_DIR}/cfg-rtbs.json"

# 分类规则与 00-discover / 01-preflight 一致：默认路由 active 且指向 IGW = 公有，其余 = 私有。
# 建议值：每个 AZ 各取一个可用 IP 最多的子网。
python3 - "${OUT_DIR}/cfg-subnets.json" "${OUT_DIR}/cfg-rtbs.json" "${SUBNETS_TSV}" <<'PY'
import json, sys
subnets = json.load(open(sys.argv[1]))["Subnets"]
rtbs = json.load(open(sys.argv[2]))["RouteTables"]
if not subnets:
    sys.exit("  （该 VPC 没有子网）")
main = next((r for r in rtbs if any(a.get("Main") for a in r.get("Associations", []))), None)
by_subnet = {a["SubnetId"]: r for r in rtbs for a in r.get("Associations", []) if a.get("SubnetId")}

def default_route(rtb):
    if not rtb:
        return "NONE", "-"
    for rt in rtb.get("Routes", []):
        if rt.get("DestinationCidrBlock") == "0.0.0.0/0":
            tgt = next((rt[k] for k in ("NatGatewayId", "TransitGatewayId", "GatewayId",
                                        "VpcPeeringConnectionId", "NetworkInterfaceId") if rt.get(k)), "-")
            return rt.get("State", "?"), tgt
    return "NONE", "-"

rows = []
for s in sorted(subnets, key=lambda s: (s["AvailabilityZone"], s["CidrBlock"])):
    rtb = by_subnet.get(s["SubnetId"], main)
    state, tgt = default_route(rtb)
    kind = "PUBLIC" if state == "active" and tgt.startswith("igw-") else "private"
    if kind == "PUBLIC":
        note = "IGW"
    elif state == "NONE":
        note = "无默认路由（部署时自动建 NAT）"
    elif state == "blackhole":
        note = "blackhole（部署时自动修复）"
    else:
        note = "出网 -> " + tgt
    name = next((t["Value"] for t in s.get("Tags", []) if t["Key"] == "Name"), "")
    rows.append([s["SubnetId"], s["AvailabilityZone"], s["CidrBlock"],
                 s["AvailableIpAddressCount"], kind, note, name])

def recommend(kind):
    best = {}
    for i, r in enumerate(rows, 1):
        if r[4] == kind and (r[1] not in best or r[3] > rows[best[r[1]] - 1][3]):
            best[r[1]] = i
    return ",".join(str(best[az]) for az in sorted(best))

print("  %-3s %-26s %-17s %-18s %-6s %-8s %-32s %s" % ("#", "SUBNET", "AZ", "CIDR", "FREE", "TYPE", "DEFAULT ROUTE", "NAME"))
for i, r in enumerate(rows, 1):
    print("  %-3s %-26s %-17s %-18s %-6s %-8s %-32s %s" % (i, *r))
with open(sys.argv[3], "w") as f:
    for r in rows:
        f.write("\t".join(str(x) for x in r) + "\n")
    # 空建议写成 "-"，避免 bash read 时相邻分隔符被合并导致字段错位
    f.write("#REC\t%s\t%s\n" % (recommend("PUBLIC") or "-", recommend("private") or "-"))
PY
read -r _ REC_PUB REC_PRI <<< "$(grep '^#REC' "${SUBNETS_TSV}" | tr '\t' ' ')"
[[ "${REC_PUB}" != "-" ]] || { REC_PUB=""; warn "该 VPC 没有公有子网（默认路由指向 IGW），NAT 网关与 internet-facing ALB 无处可放"; }
[[ "${REC_PRI}" != "-" ]] || REC_PRI=""
echo
printf '  %s\n' "公有子网：放 NAT 网关、internet-facing ALB（以及可选的运维 EC2），必须是 TYPE=PUBLIC"
printf '  %s\n' "私有子网：放 EKS 节点、Nacos、RDS，至少 2 个 AZ；无出网的子网部署时会自动建 NAT"
printf '  %s\n' "多个用逗号分隔，可填编号或子网 ID"

validate_subnets() {
  # validate_subnets <public-sel> <private-sel> -> 成功时 stdout 输出 "<pub-ids> <pri-ids>"
  python3 - "${SUBNETS_TSV}" "$1" "$2" <<'PY'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if not l.startswith("#")]
ids = {r[0]: r for r in rows}
errors, warns = [], []

def resolve(sel, label):
    out = []
    for tok in [t.strip() for t in sel.replace(" ", ",").split(",") if t.strip()]:
        if tok.isdigit() and 1 <= int(tok) <= len(rows):
            out.append(rows[int(tok) - 1][0])
        elif tok in ids:
            out.append(tok)
        else:
            errors.append("%s：无法识别 %s" % (label, tok))
    if len(set(out)) != len(out):
        errors.append("%s：有重复的子网" % label)
    return list(dict.fromkeys(out))

pub, pri = resolve(sys.argv[2], "公有子网"), resolve(sys.argv[3], "私有子网")
for sn in set(pub) & set(pri):
    errors.append("%s 同时出现在公有和私有子网里" % sn)
for sn in pub:
    if ids.get(sn, [None] * 5)[4] != "PUBLIC":
        errors.append("公有子网 %s 的默认路由没有指向 IGW，NAT 网关和 internet-facing ALB 无法使用" % sn)
for sn in pri:
    if ids.get(sn, [None] * 5)[4] == "PUBLIC":
        errors.append("私有子网 %s 的默认路由指向 IGW（实际是公有子网），节点没有公网 IP 时无法出网" % sn)
pub_az = {ids[s][1] for s in pub if s in ids}
pri_az = {ids[s][1] for s in pri if s in ids}
if len(pub_az) < 2:
    errors.append("公有子网只覆盖 %d 个 AZ，至少需要 2 个" % len(pub_az))
if len(pri_az) < 2:
    errors.append("私有子网只覆盖 %d 个 AZ，EKS 要求至少 2 个" % len(pri_az))
if pri_az - pub_az:
    warns.append("私有子网所在的 %s 没有对应的公有子网，该 AZ 的 internet-facing ALB 无法落地" % ",".join(sorted(pri_az - pub_az)))
for w in warns:
    print("  WARN  " + w, file=sys.stderr)
if errors:
    for e in errors:
        print("  FAIL  " + e, file=sys.stderr)
    sys.exit(1)
print(",".join(pub), ",".join(pri))
PY
}

while :; do
  SEL_PUB="$(ask "公有子网" "${REC_PUB}")"
  SEL_PRI="$(ask "私有子网" "${REC_PRI}")"
  if RES="$(validate_subnets "${SEL_PUB}" "${SEL_PRI}")"; then
    read -r NEW_PUB NEW_PRI <<< "${RES}"
    break
  fi
  retry_or_die; echo "  请重新选择"
done
ok "公有子网 ${NEW_PUB}"
ok "私有子网 ${NEW_PRI}"

# =============================================================================
section "4/5 网段"
VPC_CIDRS="$(python3 - "${VPCS_JSON}" "${NEW_VPC}" <<'PY'
import json, sys
v = next(v for v in json.load(open(sys.argv[1]))["Vpcs"] if v["VpcId"] == sys.argv[2])
print(",".join(a["CidrBlock"] for a in v.get("CidrBlockAssociationSet", [])
               if a["CidrBlockState"]["State"] == "associated"))
PY
)"
printf '  VPC CIDR : %s\n' "${VPC_CIDRS}"

# Nacos 额外客户端网段：模板最多接受 3 个；默认给 VPC 的全部网段（前 3 个）
DEFAULT_NACOS_CIDRS="$(cut -d, -f1-3 <<< "${VPC_CIDRS}")"
(( $(tr ',' '\n' <<< "${VPC_CIDRS}" | wc -l) > 3 )) && warn "VPC 有 3 个以上网段，Nacos 白名单最多 3 个，默认只取前 3 个"
printf '  %s\n' "除 EKS 节点外，允许哪些网段访问 Nacos 8848/9848（逗号分隔，最多 3 个；输入 - 表示只允许 EKS）"
while :; do
  NEW_NACOS_CIDRS="$(ask "Nacos 客户端网段" "${DEFAULT_NACOS_CIDRS}")"
  [[ "${NEW_NACOS_CIDRS}" == "-" ]] && { NEW_NACOS_CIDRS=""; break; }
  NEW_NACOS_CIDRS="${NEW_NACOS_CIDRS// /}"
  python3 - "${NEW_NACOS_CIDRS}" 2>/dev/null <<'PY' && break
import ipaddress, sys
items = [c for c in sys.argv[1].split(",") if c]
assert 1 <= len(items) <= 3
[ipaddress.IPv4Network(c, strict=True) for c in items]
PY
  err "网段不合法（要求逗号分隔的 IPv4 CIDR，最多 3 个）"; retry_or_die
done

# Service CIDR 不能与 VPC 网段重叠；重叠时自动给一个不冲突的候选
SUGGEST_SVC="$(python3 - "${SERVICE_IPV4_CIDR}" "${VPC_CIDRS}" <<'PY'
import ipaddress, sys
vpc = [ipaddress.ip_network(c) for c in sys.argv[2].split(",") if c]
for c in [sys.argv[1], "172.20.0.0/16", "172.30.0.0/16", "10.100.0.0/16", "192.168.0.0/16"]:
    n = ipaddress.ip_network(c)
    if not any(n.overlaps(v) for v in vpc):
        print(c); break
PY
)"
[[ "${SUGGEST_SVC}" == "${SERVICE_IPV4_CIDR}" ]] || warn "SERVICE_IPV4_CIDR=${SERVICE_IPV4_CIDR} 与 VPC 网段重叠，建议改为 ${SUGGEST_SVC}"
printf '  %s\n' "K8s Service 网段：不能与 VPC 及对等连接 / 专线 / VPN 对端网段重叠"
while :; do
  NEW_SVC="$(ask "Service CIDR" "${SUGGEST_SVC}")"
  python3 - "${NEW_SVC}" "${VPC_CIDRS}" 2>/dev/null <<'PY' && break
import ipaddress, sys
n = ipaddress.IPv4Network(sys.argv[1], strict=True)
assert 12 <= n.prefixlen <= 24
assert any(n.subnet_of(ipaddress.ip_network(p)) for p in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
assert not any(n.overlaps(ipaddress.ip_network(c)) for c in sys.argv[2].split(",") if c)
PY
  err "Service CIDR 不合法（须是 RFC1918 内 /12~/24 的网段，且不与 VPC 重叠）"; retry_or_die
done

# =============================================================================
section "5/5 确认并写回 config.env"
NEW_RTB="${PRIVATE_ROUTE_TABLE_IDS:-}"
[[ "${NEW_VPC}" == "${VPC_ID:-}" ]] || NEW_RTB=""
NEW_BASTION_SUBNET="${BASTION_SUBNET_ID:-}"
[[ -z "${NEW_BASTION_SUBNET}" || ",${NEW_PUB}," == *",${NEW_BASTION_SUBNET},"* ]] || NEW_BASTION_SUBNET=""

row() {
  if [[ "$2" == "$3" ]]; then
    printf '  %-26s %s  （不变）\n' "$1" "${3:-（空）}"
  else
    printf '  %-26s %s\n  %-26s   原值：%s\n' "$1" "${3:-（空）}" "" "${2:-（空）}"
  fi
}
row AWS_REGION               "${ORIG_REGION}"                "${AWS_REGION}"
row VPC_ID                   "${VPC_ID:-}"                   "${NEW_VPC}"
row PUBLIC_SUBNET_IDS        "${PUBLIC_SUBNET_IDS:-}"        "${NEW_PUB}"
row PRIVATE_SUBNET_IDS       "${PRIVATE_SUBNET_IDS:-}"       "${NEW_PRI}"
row PRIVATE_ROUTE_TABLE_IDS  "${PRIVATE_ROUTE_TABLE_IDS:-}"  "${NEW_RTB}"
row NACOS_EXTRA_CLIENT_CIDRS "${NACOS_EXTRA_CLIENT_CIDRS:-}" "${NEW_NACOS_CIDRS}"
row SERVICE_IPV4_CIDR        "${SERVICE_IPV4_CIDR:-}"        "${NEW_SVC}"
row BASTION_SUBNET_ID        "${BASTION_SUBNET_ID:-}"        "${NEW_BASTION_SUBNET}"

# 已经部署过的栈不会跟着迁移，改网络等于换一套环境
if [[ "${NEW_VPC}" != "${VPC_ID:-}" ]]; then
  for s in "${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_ADDONS}" "${STACK_NACOS}" "${STACK_BASTION:-}"; do
    [[ -n "${s}" ]] || continue
    st="$(stack_status "${s}")"
    [[ "${st}" == "DOES_NOT_EXIST" ]] \
      || warn "栈 ${s} 已存在（${st}）。已部署的栈不会随配置迁移，若它不在 ${NEW_VPC} 上，请先 99-destroy 再部署"
  done
fi

echo
confirm "写回 config.env？" || die "已取消，config.env 未修改"
cp -p "${CONFIG}" "${CONFIG}.bak"
python3 - "${CONFIG}" \
  "AWS_REGION=${AWS_REGION}" \
  "VPC_ID=${NEW_VPC}" \
  "PUBLIC_SUBNET_IDS=${NEW_PUB}" \
  "PRIVATE_SUBNET_IDS=${NEW_PRI}" \
  "PRIVATE_ROUTE_TABLE_IDS=${NEW_RTB}" \
  "NACOS_EXTRA_CLIENT_CIDRS=${NEW_NACOS_CIDRS}" \
  "SERVICE_IPV4_CIDR=${NEW_SVC}" \
  "BASTION_SUBNET_ID=${NEW_BASTION_SUBNET}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    # 只替换引号内的值，保留行尾注释
    text, n = re.subn(r'^(%s=)"[^"]*"' % re.escape(k), lambda m: '%s"%s"' % (m.group(1), v), text, flags=re.M)
    if n != 1:
        sys.exit("config.env 中 %s= 出现 %d 次，未写入（请手工编辑）" % (k, n))
open(path, "w", encoding="utf-8").write(text)
PY
ok "已写回 ${CONFIG}（原文件备份为 config.env.bak）"
printf '  %s\n' "下一步：./scripts/01-preflight.sh"
