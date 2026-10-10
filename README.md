# EKS + Nacos 交付包

在**客户已有的 VPC / 子网**上，用 CloudFormation 部署一套 EKS 集群，并在**独立 EC2**上部署 Nacos 作为服务发现与配置中心。

全部脚本面向 **AWS CloudShell** 设计（客户在 CloudShell 里执行即可，无需本地装任何东西）。

---

## 1. 交付内容

| 栈 | 文件 | 内容 |
|---|---|---|
| network-prereq（按需） | `cloudformation/05-network-prereq.yaml` | NAT 网关 + EIP + 修正私有子网默认路由 |
| eks-cluster | `cloudformation/10-eks-cluster.yaml` | EKS 控制面、集群 IAM 角色、KMS 信封加密、控制面日志、公有+私有端点、Access Entry |
| eks-nodegroup | `cloudformation/20-eks-nodegroup.yaml` | 托管节点组（AL2023 x86）、启动模板（IMDSv2 强制、gp3 加密根卷）、节点 IAM |
| eks-addons | `cloudformation/30-eks-addons.yaml` | pod-identity-agent / vpc-cni / kube-proxy / coredns / ebs-csi / metrics-server + ALB Controller 与 Cluster Autoscaler 的 IAM 角色和 Pod Identity 关联 |
| nacos（**可选**） | `cloudformation/40-nacos.yaml` | Nacos 2.3.2 EC2（Graviton，ASG=1 自愈）+ RDS MySQL + 内网 NLB + Secrets Manager。由 `config.env` 的 `INSTALL_NACOS` 控制 |
| bastion（**可选扩展**） | `cloudformation/50-bastion.yaml` | 公有子网跳板 / 构建机（x86 m7i.large，100 GiB，SSH + SSM 登录）：Jenkins SSH 上来把 JAR 构建成镜像推 ECR，经私有端点访问 EKS，S3 全桶读写。由 `scripts/50-bastion.sh` 单独部署/删除，见第 3 节「扩展：跳板 / 构建机」 |
| ci-ecr（**可选扩展**） | `cloudformation/60-ci-ecr.yaml` | AWS 之外的 Jenkins 推 ECR 用的身份（默认静态 AK/SK，只能推拉 `<PROJECT>/*` 仓库、只能从 Jenkins 出口 IP 使用；可选 IAM Roles Anywhere 证书）。部署 EKS 用 ServiceAccount kubeconfig。由 `scripts/60-ci-setup.sh` 单独部署/删除，见 [docs/jenkins-cicd.md](docs/jenkins-cicd.md) |

集群内组件（Helm，由 `03-post-install.sh` 安装）：AWS Load Balancer Controller、Cluster Autoscaler、gp3 默认 StorageClass。

### 架构要点

```
                     ┌─────────────────── 客户已有 VPC ───────────────────┐
  运维 / CI          │                                                    │
  ──(公网,白名单)──▶ │  EKS API Server (public + private endpoint)         │
                     │         ▲                                          │
                     │  公有子网 │  ── NAT GW ──▶ 互联网（ECR / GitHub）    │
                     │  ┌──────┴──────────────────────────────────────┐   │
                     │  │ 私有子网 (2 AZ)                              │   │
                     │  │  ┌──────────────┐        ┌────────────────┐ │   │
                     │  │  │ EKS 托管节点组│──8848─▶│ 内网 NLB       │ │   │
                     │  │  │  m7i.large x2│──9848─▶│ (8848/9848)    │ │   │
                     │  │  └──────────────┘        └───────┬────────┘ │   │
                     │  │                                  ▼          │   │
                     │  │                          ┌──────────────┐   │   │
                     │  │                          │ Nacos 2.3.2  │   │   │
                     │  │                          │ EC2 m7g.large│   │   │
                     │  │                          │ (ASG = 1)    │   │   │
                     │  │                          └──────┬───────┘   │   │
                     │  │                                 │ 3306      │   │
                     │  │                          ┌──────▼───────┐   │   │
                     │  │                          │ RDS MySQL 8.0│   │   │
                     │  │                          └──────────────┘   │   │
                     │  └──────────────────────────────────────────────┘   │
                     └────────────────────────────────────────────────────┘
```

**为什么 Nacos 用 ASG=1 而不是裸 EC2**：配置数据全部落在 RDS，EC2 是无状态的。ASG 固定 1 台 + NLB 健康检查，实例故障时自动替换并重新注册到 NLB，接入地址（NLB DNS）不变，业务侧无需改配置。要升级成 3 节点集群时，把 ASG 容量改成 3 并补 `cluster.conf` 寻址即可，网络与数据层不用动。

---

## 2. 前置要求

- 客户 AWS 账号，有 EKS / EC2 / RDS / IAM / CloudFormation / Secrets Manager 权限
- VPC 已存在，且**至少 2 个 AZ** 各有一个公有子网和一个私有子网
- 公有子网默认路由指向 IGW（用于放 NAT 网关和 internet-facing ALB）
- 私有子网需要能出网（拉 ECR 镜像、下载 Nacos 安装包）。**如果没有 NAT，脚本会自动创建并修好路由**
- VPC 必须开启 `enableDnsSupport` + `enableDnsHostnames`。**没开的话脚本会在建集群前自动开启**（见下方「两个会让部署静默卡死的网络前提」）
- CloudShell 里执行；kubectl / helm 由 `install-tools.sh` 装到 `~/.local/bin`

### 两个会让部署静默卡死的网络前提

这两项在客户"已有 VPC"场景里踩中概率很高，而且**报错方向极具误导性**，所以脚本做了自动检测与修复（`FIX_VPC_DNS` / `CREATE_NAT_GATEWAY`）。

**① VPC 没开 `enableDnsHostnames`**（本次交付演练实测踩到）

EKS 启用私有端点时会创建一个由 `eks.amazonaws.com` 托管的 Route 53 私有托管区，但**私有托管区只在 `enableDnsSupport` 和 `enableDnsHostnames` 同时为 true 时才对 VPC 生效**。属性缺一个，节点就会把集群端点解析成**公网 IP**，转而走 NAT 访问公共端点 —— 而公共端点的 CIDR 白名单里没有 NAT 的 EIP，于是节点永远注册不上。

故障表象会把人带到完全错误的方向：

- EC2 实例正常 `running`，SSM Session Manager 能连上（说明出网完全正常）
- `aws eks describe-nodegroup` 的 `health.issues` 是**空数组**，`status` 长时间停在 `CREATING`
- 二十多分钟后才以 `NodeCreationFailure: Instances failed to join the kubernetes cluster` 超时失败，错误信息完全不提 DNS

判断方法（在节点上，用 SSM 登录）：

```bash
getent hosts <cluster-endpoint-hostname>
# 返回公网 IP  -> DNS 属性有问题
# 返回 10.x.x.x -> 正常（私有端点 ENI 的地址）
```

**② 私有子网默认路由是 blackhole**（同样实测踩到）

NAT 网关被删除后，路由表里的 `0.0.0.0/0 -> nat-xxx` 不会自动清理，而是变成 `blackhole` 状态。控制台上看"有默认路由"，实际完全不通。此时：

- 节点起不来（拉不到 ECR 镜像）
- Nacos 下载不了安装包
- 而且直接建 NAT 后补路由会因 `RouteAlreadyExists` 失败 —— 必须先删掉残留路由

`02-deploy.sh` 的处理顺序是：反查私有子网路由表 → 删除 blackhole 残留路由 → 建 NAT + EIP → 补路由 → 复核。

---

## 3. 部署步骤

```bash
# 0) 在 CloudShell 里拿到这个目录（上传 zip 或 git clone），然后
cd eks_delivery
chmod +x scripts/*.sh

# 1) 装 kubectl / helm（CloudShell 默认不带；装到 $HOME 才能跨会话保留）
./scripts/install-tools.sh
export PATH="$HOME/.local/bin:$PATH"

# 2) 编辑唯一的配置文件：按下方「配置替换清单」修改项目名、环境名等
#    （VPC / 子网不用手填，第 3 步的向导会带你选）
vi config.env

# 3) 只读预检。首次运行时会发现 config.env 里的 VPC / 子网是示例值，
#    自动进入「网络配置向导」：确认区域 -> 选 VPC -> 选公有 / 私有子网 -> 写回 config.env
./scripts/01-preflight.sh

# 4) 部署全部栈（约 25-35 分钟）
./scripts/02-deploy.sh

# 5) 装集群内组件
./scripts/03-post-install.sh

# 6) 端到端验收
./scripts/04-verify.sh                 # 基础验收
./scripts/04-verify.sh --all           # 额外实测 EBS 动态供给 + 真实 ALB（会产生少量费用）
```

### 网络配置向导

`config.env` 随包附带的 VPC / 子网 ID 是交付方演练环境的示例值，在你的账号里不存在。`01-preflight.sh` 一开始会检查这些 ID 在**当前账号 + 区域**是否有效，无效时自动进入向导（向导只改 `config.env`，不改任何 AWS 资源）：

| 步骤 | 向导做什么 | 你要做什么 |
|---|---|---|
| 1/5 区域 | 显示当前账号与身份 | 确认或输入部署区域 |
| 2/5 VPC | 列出该区域所有 VPC（ID / CIDR / 是否默认 / 名称） | 输入编号或 VPC ID |
| 3/5 子网 | 列出 VPC 内所有子网，按默认路由自动标出 `PUBLIC`（指向 IGW）/ `private`，显示 AZ、可用 IP、出网方式，并**按每个 AZ 可用 IP 最多**给出建议 | 回车采用建议，或输入编号 / 子网 ID（逗号分隔） |
| 4/5 网段 | 读取 VPC CIDR；建议 Nacos 客户端网段 = VPC CIDR；检查 Service CIDR 是否与 VPC 重叠，重叠时给出替代值 | 回车采用建议，或自行输入 |
| 5/5 确认 | 列出每个变量的原值 → 新值；若同名栈已部署会提醒 | 输入 `y` 写回（原文件备份为 `config.env.bak`） |

子网选择的校验规则（不通过会提示原因并让你重选）：

- 公有子网必须是 `PUBLIC`（默认路由 active 且指向 IGW），且覆盖至少 2 个 AZ
- 私有子网不能是 `PUBLIC`，且覆盖至少 2 个 AZ；**无默认路由或 blackhole 的私有子网可以选**，`02-deploy.sh` 会自动建 NAT / 修路由（见第 2 节②）
- 同一个子网不能同时出现在公有和私有里
- 私有子网所在 AZ 没有对应公有子网时给出警告（该 AZ 的 internet-facing ALB 无法落地）

其他用法：

```bash
./scripts/01-preflight.sh --configure                        # 配置有效也强制重新选择
./scripts/configure-network.sh                               # 单独运行向导
ASSUME_YES=1 ./scripts/configure-network.sh vpc-xxxxxxxx     # 无人值守（CI）：子网与网段全部采用建议值
```

> 向导写回的变量：`AWS_REGION` / `VPC_ID` / `PUBLIC_SUBNET_IDS` / `PRIVATE_SUBNET_IDS` / `PRIVATE_ROUTE_TABLE_IDS`（换 VPC 时清空，由脚本自动反查）/ `NACOS_EXTRA_CLIENT_CIDRS` / `SERVICE_IPV4_CIDR` / `BASTION_SUBNET_ID`（不在新公有子网里时清空）。`02-deploy.sh` 也会做同样的有效性检查，网络配置无效时直接拒绝部署。
>
> `00-discover.sh <vpc-id>` 仍保留，作为只读的网络详情报告（NAT / IGW / VPC Endpoint / 子网已有的 k8s 标签），排查网络问题时使用。

### 配置替换清单（部署前必读）

`config.env` 随包附带的是交付方**演练环境的示例值**，直接使用会失败（ID 在你的账号里不存在）或产生不符合你环境的配置。网络相关项由上面的向导填写，其余请按下表逐项替换，文件里对应行已用 `【必改】`（必须替换）/ `【生产】`（生产必须收紧）标出。

**① 必须替换**

| 变量 | 示例值（勿直接使用） | 怎么取你自己的值 |
|---|---|---|
| `AWS_REGION` | `ap-southeast-1` | **向导第 1 步**确认。也可直接改：CloudShell 里 `echo $AWS_REGION` 可查看当前控制台区域 |
| `PROJECT` | `sharetronic` | 你的项目名（小写字母/数字/连字符）。所有资源名、标签、Secrets 路径都以它为前缀 |
| `ENVIRONMENT` | `test` | `test` / `staging` / `prod` 之一 |
| `VPC_ID` | `vpc-EXAMPLE00000000000` | **向导第 2 步**选择 |
| `PUBLIC_SUBNET_IDS` | `subnet-EXAMPLEPUBLIC0001,…` | **向导第 3 步**选择，至少 2 个不同 AZ |
| `PRIVATE_SUBNET_IDS` | `subnet-EXAMPLEPRIVATE001,…` | **向导第 3 步**选择，至少 2 个不同 AZ，与公有子网 AZ 对应 |
| `NACOS_EXTRA_CLIENT_CIDRS` | `10.10.0.0/16` | **向导第 4 步**，默认建议你的 VPC CIDR；只给 EKS 用就输入 `-` |
| `SERVICE_IPV4_CIDR` | `172.20.0.0/16` | **向导第 4 步**自动检查与 VPC 的重叠。向导只知道 VPC 网段，**对等连接 / 专线 / VPN 对端网段请自行确认不重叠** |

**② 生产环境必须收紧**（测试环境可保留默认）

| 变量 | 默认 | 生产建议 |
|---|---|---|
| `API_PUBLIC_ACCESS_CIDRS` | `auto`（当前出口 IP/32） | 你的办公网 / VPN / CI 出口段，如 `203.0.113.0/24`。注意：`auto` 时每次重跑 `02-deploy.sh` 都会把白名单重置为当前 IP |
| `FIX_API_WHITELIST` | `auto` | `false`，白名单变更由运维显式执行 `allow-my-ip.sh` |
| `NACOS_DB_MULTI_AZ` | `false` | `true` |
| `NACOS_DB_DELETION_PROTECTION` | `false` | `true`（开启后 `99-destroy.sh` 删不掉 RDS，需先手工关闭） |
| `NACOS_DB_BACKUP_RETENTION` | `7` | 按你的备份策略；若账号里有 AWS Backup 计划会覆盖此值，请对齐（见第 7 节排障表） |
| `BASTION_SSH_CIDRS` | `auto` | 办公网出口段；或不开 SSH、只用 SSM 登录 |

**③ 按需调整**

| 变量 | 什么时候改 |
|---|---|
| `ADMIN_PRINCIPAL_ARN` | 需要让**部署者以外**的 IAM 角色（运维组 / CI）也拥有集群管理员权限时填写 |
| `INSTALL_NACOS` | 已有 Nacos、只要 EKS 时设 `false` |
| `NODE_INSTANCE_TYPES` / `NODE_*_SIZE` / `NODE_CAPACITY_TYPE` | 按业务容量；先用 `01-preflight.sh` 确认机型在你的 AZ 可用 |
| `NACOS_INSTANCE_TYPE` / `NACOS_DB_INSTANCE_CLASS` | 按配置中心规模 |
| `NACOS_DOWNLOAD_BASE_URL` | 私有子网**访问不了 GitHub** 时，改成你内部 S3 / 制品库前缀（目录结构需与 GitHub Release 一致） |
| `CREATE_NAT_GATEWAY` | 私有子网已通过 TGW / 防火墙出网，或已配好 VPC Endpoint 时设 `false` |
| `CLUSTER_NAME` | 默认 `${PROJECT}-eks`。**同一账号同一区域部署多套环境**时改成 `${PROJECT}-${ENVIRONMENT}-eks`，否则集群及 IAM / KMS 名称会冲突 |

替换完成后跑只读预检，它会逐项核对 VPC、子网、AZ、路由、DNS 属性、机型可用性与 IP 容量，任何一项不符都会在改动资源之前报出：

```bash
./scripts/01-preflight.sh
```

> 文档中出现的 `sharetronic` / `test` / `sharetronic-eks` 等名称均为示例，请按你的 `PROJECT` / `ENVIRONMENT` / `CLUSTER_NAME` 替换。

> `04-verify.sh` 会自己写 kubeconfig，**不依赖第 5 步**。所以即使只想验收集群、不装 Helm 组件，也可以直接跑第 6 步。

### Nacos 是可选的

客户已有 Nacos，或只想先把 EKS 验通时，把 `config.env` 里的开关关掉即可：

```bash
INSTALL_NACOS="false"
```

关掉之后各脚本的行为：

| 脚本 | 行为 |
|---|---|
| `01-preflight.sh` | 跳过 Nacos 机型（`m7g.large`）可用性检查 |
| `02-deploy.sh` | 跳过阶段 5，阶段编号自动变成 `1/4`～`4/4`，预计耗时提示改为 15–20 分钟 |
| `03-post-install.sh` | 跳过下发 `nacos-config` ConfigMap |
| `04-verify.sh` | 栈清单里不要求 nacos 栈存在；第 7 节标记为「按配置跳过」，不计入失败 |
| `99-destroy.sh` | **不受开关影响**，始终尝试清理 Nacos 相关资源（以防之前部署过后又把开关关掉，留下计费资源） |

只关 EKS 不关 Nacos 时，只部署 4 个栈，月成本从约 $500 降到约 **$350**（省掉 Nacos EC2、RDS、内网 NLB）。

后来又想加上 Nacos：

```bash
sed -i 's/^INSTALL_NACOS=.*/INSTALL_NACOS="true"/' config.env
./scripts/02-deploy.sh nacos       # 只跑阶段 5，不动已有的 4 个栈
./scripts/03-post-install.sh       # 下发 nacos-config
./scripts/04-verify.sh             # 补验 Nacos
```

> `./scripts/02-deploy.sh nacos` 显式指定阶段时**会忽略 `INSTALL_NACOS=false`**（显式意图优先），只是会打一条 warn 提示。

在 CloudShell 里建议用 `bg.sh` 起长任务，能扛住刷新浏览器和短暂断网：

```bash
./scripts/bg.sh 02-deploy.sh      # 挂进 tmux 跑 + 实时跟随日志
./scripts/bg.sh --status          # 看是否在跑 + 5 个栈状态（重连后先跑这个）
./scripts/bg.sh --attach          # 回到 tmux 会话（脱离：Ctrl-b 再按 d）
./scripts/bg.sh --log             # 只跟日志（Ctrl-C 不影响后台任务）
```

### 用 2048 示例做一次真实 ALB 端到端验证

`04-verify.sh --all` 里已包含一次自建 Ingress 的 ALB 冒烟（建完即删）。如果想要一个**可以用浏览器打开**的直观验证，用官方 2048 示例：

```bash
# 部署（该清单自带 Namespace，不需要加 -n game-2048）
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/examples/2048/2048_full.yaml

# 等 ADDRESS 出现（约 2-4 分钟：ALB 要从 provisioning 变 active）
kubectl -n game-2048 get ingress ingress-2048 -w
```

拿到 ADDRESS 后在浏览器打开，或命令行验证：

```bash
ALB=$(kubectl -n game-2048 get ingress ingress-2048 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w 'HTTP %{http_code}\n' "http://${ALB}/"     # 期望 200
```

这个测试同时验证了三条链路：

| 观察点 | 说明 |
|---|---|
| ALB 落在**公有子网** | 证明 `kubernetes.io/role/elb=1` 子网标签自动发现生效 |
| 目标组里是 **Pod IP** 而非节点 NodePort | 清单用了 `target-type: ip`，证明 VPC CNI 与控制器集成正常 |
| 5 个目标全 `healthy` + HTTP 200 | 证明安全组、路由、健康检查全链路通 |

想看目标组细节：

```bash
ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${ALB}'].LoadBalancerArn|[0]" --output text)
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --load-balancer-arn "$ARN" --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
```

**测完一定要删**，否则这个 internet-facing ALB 会一直计费（约 $0.023/小时 + LCU）：

```bash
kubectl delete -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/examples/2048/2048_full.yaml

# 确认 ALB 真的被回收了（控制器异步删除，约 1-2 分钟）
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,Type,State.Code]" --output text
```

> 忘记删也不会漏掉：`99-destroy.sh` 第 1 步会删除所有 namespace 下的 Ingress 和 `type=LoadBalancer` Service，等控制器回收完 ALB/NLB 之后才开始删栈。

### CloudShell 注意事项

- **会话断开不影响部署**。CloudFormation 在 AWS 侧异步执行，脚本只是在轮询。断开后重连直接重跑即可：已完成的栈走「无变更」路径，进行中的栈会先等它结束。也可以只跑某一阶段：
  `./scripts/02-deploy.sh nacos`（阶段名：`network` / `cluster` / `nodegroup` / `addons` / `nacos`）
- **前台进程会被杀，`nohup` 救不了**。CloudShell 终端是浏览器 WebSocket，断开时进程收到 SIGHUP；闲置约 20–30 分钟后整个容器被回收，`nohup` / `setsid` / `tmux` 一并消失。用 `bg.sh` 可以扛住刷新和短暂断网，但扛不住闲置超时。会话最长 12 小时。
- **重连后记得** `export PATH="$HOME/.local/bin:$PATH"`（`install-tools.sh` 已写入 `~/.bashrc`，也可以 `source ~/.bashrc`）。`$HOME` 会跨会话保留，`$HOME` 之外全部重置。
- **CloudShell 出口 IP 会轮换**。`config.env` 里 `API_PUBLIC_ACCESS_CIDRS="auto"` 表示部署时自动取当前出口 IP/32。之后若 IP 变了导致 kubectl 连不上：
  ```bash
  ./scripts/allow-my-ip.sh            # 追加当前出口 IP（只追加，不会踢掉别人）
  ./scripts/allow-my-ip.sh --list     # 只看当前白名单
  ./scripts/allow-my-ip.sh --replace  # 只保留当前出口 IP
  ```
  `FIX_API_WHITELIST="auto"` 时，`03` / `04` 脚本发现是这个原因会自动追加。这是对集群的带外修改，记得把最终白名单同步回 `config.env` 保持 IaC 一致；生产交付建议设成 `false`，由运维显式授权。

### 扩展：Graviton（arm64）节点组

与 x86 节点组 `ng-general` 并存的 arm64 托管节点组 `ng-arm64`（默认 `m8g.large`，备选 `m7g.large`，AL2023 ARM，IMDS 跳数 1），Cluster Autoscaler 自动发现、一起管理，无需改 CAS 配置。配置项见 `config.env` 的「扩展：Graviton 节点组」段。

```bash
./scripts/55-arm-nodegroup.sh               # 部署 / 更新（幂等，约 3-5 分钟），结束后自动验收
./scripts/55-arm-nodegroup.sh verify        # 验收：AWS 侧配置 + 集群内冒烟
./scripts/55-arm-nodegroup.sh test-scale    # CAS 扩容测试（WAIT_SCALE_DOWN=1 同时等待缩容）
./scripts/55-arm-nodegroup.sh info          # 状态 + 应用接入示例
./scripts/55-arm-nodegroup.sh destroy       # 删除（99-destroy 也会在删集群前删它）
./tests/test-55-arm-nodegroup.sh            # 离线测试（不访问 AWS）
```

要点：
- **默认带 taint `arch=arm64:NoSchedule`**。Kubernetes 调度时不检查镜像架构，只有 amd64 的镜像落到 arm 节点会 `exec format error`。应用镜像改成多架构（`docker buildx --platform linux/amd64,linux/arm64`）后，再加容忍迁移过来：
  ```yaml
  nodeSelector: { kubernetes.io/arch: arm64 }
  tolerations:
    - { key: arch, operator: Equal, value: arm64, effect: NoSchedule }
  ```
- **min 默认 0**。节点组的 Tags 不会传到 ASG，脚本部署后给 ASG 补 `k8s.io/cluster-autoscaler/node-template/{label,taint}/*` 标签，CAS 才能从 0 台扩容，也能识别 taint，不会为没有容忍的 Pod 扩 arm 节点。
- 再次部署时沿用当前的 desired（夹在 min 到 max 之间），不会把 CAS 调过的节点数打回配置值。
- 子网默认复用 `ng-general`。机型会预检是否为 arm64、各 AZ 是否有供给。
- 验收里的集群内检查：本机 kubectl 连得上就在本机跑，连不上就经跳板机 SSM 执行（`ARM_KUBE_VIA`），**不会自动改 API 白名单**。内容包括：冒烟 Pod 输出 `uname -m` = `aarch64`；节点的 arch 标签和 taint；DaemonSet 全部 Running；不带容忍的 Pod 会被 taint 挡住。

### 扩展：跳板 / 构建机（x86，Jenkins SSH 构建推 ECR，可访问 EKS）

一台放在公有子网的 x86 EC2：外部 Jenkins 用 SSH 登录，上传 JAR，在这台机器上 `docker build` 成 linux/amd64 镜像并推到 ECR；同时它经 EKS **私有端点**访问集群（kubectl，集群管理员）和节点，也可当 S3 数据中转机。**独立于主栈**：需要 EKS 已存在，但不修改 EKS 相关的任何栈，`02-deploy.sh` 和 `99-destroy.sh` 也都不会碰它。以下命令都在 CloudShell 里执行。

```bash
./scripts/50-bastion.sh                # ① 部署 / 更新：交互式只问「Jenkins 出口 IP」，约 8 分钟，结束自动验收
./scripts/50-bastion.sh jenkins        # ② 打印 Jenkins 要配的凭据 / 全局变量 / 主机指纹 / 插件 / 私钥下载路径
./scripts/50-bastion.sh test-build     # ③ 可选：机上编译示例 JAR -> 构建推 ECR -> 在 EKS 跑起来并 curl
./scripts/50-bastion.sh info           # 再次查看连接信息
./scripts/50-bastion.sh verify         # 重新验收：docker / buildx / ECR 登录 / kubectl / 节点 / 私有端点 / S3
./scripts/50-bastion.sh ssm            # SSM 登录（不需要密钥，也不依赖 22 端口白名单）
./scripts/50-bastion.sh ssh            # SSH 登录（私钥已自动放在 ~/.ssh/）
./scripts/50-bastion.sh key            # 重新取回 Jenkins 用的私钥到 ~/.ssh/
./scripts/50-bastion.sh allow-my-ip    # 当前出口 IP 不在 SSH 白名单时追加
./scripts/50-bastion.sh install-tools  # 只更新机上的 build-push-jar（改了 scripts/bastion/ 之后）
./scripts/50-bastion.sh destroy        # 删除（实例、EIP、安全组、角色、集群安全组里放行本机的规则、Access Entry）
```

> **傻瓜式步骤（部署 + 现有 Jenkins 配置）见 [docs/bastion-upgrade.md](docs/bastion-upgrade.md)**。老版本（arm / t4g.large）的配置会被自动改成 x86 默认值；旧跳板机实例已手动删除时脚本会自动清理旧栈重建。

Jenkins 侧的配置与流水线见 **[docs/jenkins-cicd.md「方式二：跳板机构建」](docs/jenkins-cicd.md#10-方式二跳板机构建jenkins-ssh-上传-jar)**，示例流水线 `ci/Jenkinsfile.bastion-jar.example`。

| 项 | 默认 | 说明 |
|---|---|---|
| 机型 / 系统 | `m7i.large`（x86_64，2 vCPU / 8 GiB）/ AL2023 | AMI 由 `describe-images` 按机型架构自动解析；根卷 **100 GiB** gp3 加密，IMDSv2 强制 |
| 构建工具 | docker + buildx、kubectl（与集群同版本）、`build-push-jar` | docker 日志限大小，每周自动清理悬空镜像 / 构建缓存 |
| 子网 | `PUBLIC_SUBNET_IDS` 第一个 | 脚本会校验默认路由指向 IGW，并检查该 AZ 是否提供该机型 |
| 公网 IP | 弹性 IP | `BASTION_ALLOCATE_EIP=false` 则用临时公网 IP（停机再启动会变） |
| SSH 白名单 | `auto` = 当前出口 IP/32，并合并 `JENKINS_EGRESS_CIDRS` | 合计最多 5 个 CIDR；填 `0.0.0.0/0` 会二次确认。`allow-my-ip` 是带外追加，栈更新不会冲掉 |
| 密钥对 | 自动创建 | 栈自动创建 `<PROJECT>-<ENV>-bastion-key`，私钥托管在 SSM Parameter Store，部署后保存到 CloudShell `~/.ssh/`；丢了用 `./scripts/50-bastion.sh key` 重新取回。随栈删除 |
| EKS 访问 | 私有端点 + 集群管理员 | 在集群安全组加一条「来自本机安全组」的入站规则（控制面 443 与托管节点都用这个安全组，所以 API 和节点都能直连），并给实例角色建 Access Entry（`AmazonEKSClusterAdminPolicy`）。`BASTION_EKS_ACCESS=none` 只放通网络不授权 |
| ECR 权限 | `<PROJECT>/*` 仓库推拉 + 自动建库 | 实例角色，Jenkins 上不需要任何 AWS 凭证 |
| S3 权限 | 所有桶：列举 / 下载 / 上传 | 含分片上传、对象标签、版本读取；含经由 S3 的 KMS 解密/加密，所以 SSE-KMS 桶也能用。**默认不含删除**，需要时设 `BASTION_S3_ALLOW_DELETE=true` 后重跑 |

实例内直接用实例角色的凭证，不需要 `aws configure`，区域也已预设：

```bash
aws s3 ls
aws s3 cp ./data.tar.gz s3://<bucket>/backup/
aws s3 sync s3://<bucket>/prefix ./local-dir
```

注意：

- "所有桶"指 IAM 层面对 `arn:aws:s3:::*` 授权。**桶策略里有显式 Deny 的桶**（如只允许特定 VPC Endpoint / 特定角色）、以及**其他账号的桶**，仍需对方桶策略放行。
- SSE-KMS 桶如果用的是客户自管 CMK，且 key policy 没有把权限委托给 IAM（没有 `arn:aws:iam::<账号>:root` 那条语句），需要在 key policy 里加上本实例角色。
- 这台机器能访问 Nacos：NLB 安全组已放行 `NACOS_EXTRA_CLIENT_CIDRS`，只要它包含公有子网网段即可。访问 EKS 走私有端点，**不需要**把 EIP 加进 API 公网白名单；集群若关闭了私有端点，`verify` 会报出来。
- 实例被替换（改机型 / AMI 更新）后 SSH 主机密钥会变，重跑 `./scripts/50-bastion.sh jenkins` 更新 Jenkins 的 `BASTION_HOST_KEY`。
- 数据只放在根卷上，`destroy` 会随实例一起删除，需要保留的文件请先传到 S3。

### 扩展：外部 Jenkins 推 ECR + 部署 EKS

Jenkins 不在 AWS 上、也不想在上面配 `aws configure` 时使用。**完全独立**，`02-deploy.sh` / `99-destroy.sh` 都不会碰它。完整说明（Jenkins 凭据导入、流水线、轮换、排障）见 **[docs/jenkins-cicd.md](docs/jenkins-cicd.md)**。

```bash
vi config.env                          # 「扩展：外部 Jenkins CI/CD」段，至少填 JENKINS_EGRESS_CIDRS（Jenkins 出口 IP）
./scripts/60-ci-setup.sh               # 部署 / 更新（幂等），生成交接目录 ~/<PROJECT>-<ENV>-jenkins-bundle 并自动验收
./scripts/60-ci-setup.sh info          # 再次查看交接目录与 Jenkins 配置要点
./scripts/60-ci-setup.sh rotate-key    # 轮换 ECR 访问密钥（先建新的，确认后删旧的）
./scripts/60-ci-setup.sh destroy       # 删除
```

- 推 ECR：默认 `CI_ECR_AUTH=accesskey`，一对静态 AK/SK，只能推拉 `<PROJECT>/*` 仓库，且只能从 `JENKINS_EGRESS_CIDRS` 使用；对长期密钥有合规限制时改为 `rolesanywhere`（证书换 1 小时临时凭证，Jenkins 自动完成）
- 部署 EKS：kubeconfig 内含 ServiceAccount token，只对 `CI_NAMESPACES` 有权限，不需要 aws CLI
- 会把 `JENKINS_EGRESS_CIDRS` **追加**进 EKS 公共端点白名单（带外修改，记得同步 `API_PUBLIC_ACCESS_CIDRS`）
- 流水线示例：`ci/Jenkinsfile.example`（构建 → 推 ECR → 部署 → 校验镜像版本）

### 清理

```bash
./scripts/99-destroy.sh                 # 逆序清理（会二次确认）
KEEP_NETWORK=1 ./scripts/99-destroy.sh  # 保留 NAT 网关
```

> 跳板 / 构建机与 Jenkins CI 两个扩展栈不在 `99-destroy.sh` 的清理范围内（残留检查里会提示）；删除用 `./scripts/50-bastion.sh destroy` 与 `./scripts/60-ci-setup.sh destroy`。先删集群也可以，CI 扩展的 destroy 会跳过 K8s 侧只清 IAM。

清理顺序有讲究：先删集群内的 Ingress 和 `type=LoadBalancer` Service，让控制器把它自己创建的 ALB/NLB 回收掉；否则这些 CFN 不知道的资源会挂在子网/安全组上，导致栈删不干净。

---

## 4. 关键设计决策

| 项 | 选择 | 理由 |
|---|---|---|
| EKS 版本 | **1.36** | 2026-09 的默认版本，标准支持至 2027-08-02，patch 1.36.4 |
| API Server 端点 | 公有 + 私有，公网带 CIDR 白名单 | 运维可从外网直连；集群内部流量走私有端点不出 VPC |
| 鉴权模式 | `API_AND_CONFIG_MAP` | 支持新的 Access Entry，同时兼容仍在读写 `aws-auth` configmap 的存量工具链 |
| 工作节点 | 托管节点组，AL2023 x86（m7i） | 客户选 x86 以保证存量镜像兼容；托管节点组的滚动升级和排水由 AWS 负责 |
| Addon 版本 | **不写死**，用 EKS 默认版本 | 跨区域、跨时间都能部署成功；`01-preflight.sh` 会打印实际解析到的版本供交付存档 |
| 控制器授权 | **EKS Pod Identity**（非 IRSA） | 不需要创建 OIDC provider、不需要给 ServiceAccount 加注解，角色信任策略更简单 |
| vpc-cni 授权 | 例外，放在**节点 IAM 角色**上 | CNI 要在节点 Ready 之前工作，用 Pod Identity 会形成循环依赖 |
| 节点弹性 | Cluster Autoscaler | 与托管节点组的 ASG 天然对齐（EKS 自动打 `k8s.io/cluster-autoscaler/*` 标签，无需额外配置）。需要更细粒度的机型选择和更快扩容时再迁 Karpenter |
| Nacos 版本 | **2.3.2**（客户指定） | 与 Spring Cloud Alibaba 主流版本兼容性最好 |
| Nacos 持久化 | RDS MySQL 8.0 | 不用内嵌 Derby，EC2 重建不丢配置 |
| Nacos 凭证 | 全部由 Secrets Manager 随机生成 | 模板和仓库里不出现任何口令；运行时只写 tmpfs `/run`，不落磁盘 |
| Nacos 接入地址 | 内网 NLB（8848 + 9848） | 地址稳定，与实例生命周期解耦；Nacos 2.x 客户端必须同时能连 9848 gRPC |
| AMI 解析 | `ec2:DescribeImages`，**不用** `{{resolve:ssm:/aws/service/...}}` | 该账号 SSO 角色被 SCP 禁止读 `/aws/` 命名空间的 SSM 公共参数，动态引用会让栈直接失败 |
| ALB Controller IAM 策略 | 固化在 `iam/` 目录 | 部署过程不依赖外网拉 GitHub，可复现；chart 3.5.0 与 2.x 线的策略内容完全一致 |

---

## 5. 安全基线

- API Server 公共端点默认只放行 `config.env` 里列出的 CIDR
- etcd 中的 Kubernetes Secret 用新建的 KMS CMK 做信封加密（`ENABLE_SECRETS_ENCRYPTION=true`）
- 控制面 5 类日志（api / audit / authenticator / controllerManager / scheduler）全开，投递到 CloudWatch，保留 30 天
- 节点与 Nacos 实例强制 IMDSv2；节点 IMDS hop limit = 2，容器无法直接读实例元数据
- 所有 EBS 卷、RDS 存储加密
- 不开任何 SSH 入站；节点和 Nacos 都用 SSM Session Manager 登录（唯一例外是可选扩展「跳板 / 构建机」，其 22 端口只对 `BASTION_SSH_CIDRS` + `JENKINS_EGRESS_CIDRS` 白名单开放）
- Nacos 开启鉴权（`nacos.core.auth.enabled=true`）+ server identity，匿名请求被拒绝（验收脚本第 4 项会实测）
- Nacos 2.3.x 自带的默认口令 `nacos/nacos` 在首次部署时被替换为 Secrets Manager 生成的随机口令

### 交付后建议客户补的事项（本包未包含）

- Nacos 为每个业务应用单独建用户并授权到对应 namespace，**不要让业务用 admin 账号**
- RDS 连接改成 `sslMode=VERIFY_IDENTITY` 并导入 RDS CA bundle（当前是 `PREFERRED`：加密但不校验证书）
- 生产环境把 `NACOS_DB_MULTI_AZ` 和 `NACOS_DB_DELETION_PROTECTION` 改为 `true`
- Secrets Manager 自动轮转、集群审计日志告警、Pod 安全准入（PSA）策略

---

## 6. 业务侧接入 Nacos

`03-post-install.sh` 会在 `app` namespace 下创建 `ConfigMap/nacos-config`：

```yaml
env:
  - name: SPRING_CLOUD_NACOS_SERVER_ADDR
    valueFrom: { configMapKeyRef: { name: nacos-config, key: NACOS_SERVER_ADDR } }
# 或整体注入
envFrom:
  - configMapRef: { name: nacos-config }
```

Spring Cloud Alibaba 配置示例：

```yaml
spring:
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_SERVER_ADDR}   # <内网NLB DNS>:8848
        username: ${NACOS_USERNAME}
        password: ${NACOS_PASSWORD}
      config:
        server-addr: ${NACOS_SERVER_ADDR}
        username: ${NACOS_USERNAME}
        password: ${NACOS_PASSWORD}
        file-extension: yaml
```

> Nacos 2.x 客户端除 8848（HTTP）外还会用 `8848+1000 = 9848`（gRPC 长连接）。NLB 两个端口都已监听，安全组也都放通；如果业务侧报连接超时，先确认 9848 通不通（验收脚本第 9 项会测）。

### 访问控制台

NLB 是内网地址，从 CloudShell/本地需要转发：

```bash
# 取控制台口令
aws secretsmanager get-secret-value --region ap-southeast-1 \
  --secret-id sharetronic/test/nacos/console-admin \
  --query SecretString --output text

# 通过 SSM 端口转发（在 VPC 内的实例上做跳板）
aws ssm start-session --region ap-southeast-1 --target <nacos-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8848"],"localPortNumber":["8848"]}'
# 然后浏览器打开 http://localhost:8848/nacos
```

---

## 7. 排障

| 现象 | 排查方向 |
|---|---|
| **节点组长时间 CREATING、`health.issues` 为空、实例却 running** | **首查 VPC DNS 属性**（见第 2 节①）。在节点上 `getent hosts <集群端点>`，返回公网 IP 就是这个问题。`01-preflight.sh` 第 6 项会检出 |
| 节点一直不 Ready | 私有子网出网。`01-preflight.sh` 第 7 项会检出 blackhole / 缺失默认路由 |
| 节点 Ready 但 Pod ImagePullBackOff | 同上（拉不到 ECR）；或节点 IAM 缺 `AmazonEC2ContainerRegistryReadOnly` |
| kubectl 连不上（三种，见下方专节） | `setup_kubeconfig` 会自动分类诊断并给出对应修复命令 |
| Ingress 建不出 ALB | 子网缺 `kubernetes.io/role/elb=1` 标签（`04-verify.sh` 第 5b 项会检）；或控制器 Pod 没拿到 Pod Identity 凭证（第 5 项会检） |
| Nacos NLB 目标 unhealthy | `aws ssm start-session --target <id>`，看 `/var/log/nacos-bootstrap.log` 和 `journalctl -u nacos`；CloudWatch 日志组 `/sharetronic/test/nacos` |
| Nacos 起不来，日志报数据库连不上 | 检查 RDS 是否 available、`nacos-secrets.service` 是否成功写了 `/run/nacos-secrets/env` |
| 业务能注册但拉不到配置 | Nacos 开了鉴权，客户端必须带 username/password |
| 配置刚发布就读不到（`config data not exist`） | 不是故障。Nacos 先写 MySQL，再异步 dump 到本地缓存，而读接口走缓存，实测约 2 秒后可读。客户端 SDK 自带重试，只有手写 curl 脚本才会遇到 |
| RDS 的备份保留期/窗口与模板不一致，CFN 报配置漂移 | 账号里有 AWS Backup 计划匹配到了这个实例并自行改了 `backupRetentionPeriod` / `preferredBackupWindow`（交付演练时实测到账号内已有的 Backup 计划把 7 天改成 35 天）。在你的账号 `<你的 AWS Account ID>` 里用 `aws backup list-backup-plans` 列出计划，再用 `aws backup list-backup-selections --backup-plan-id <计划ID>` 看是否按标签 / 资源类型匹配到了 RDS。要么把 Nacos 的 RDS 实例从该计划的资源选择里排除，要么把 `NACOS_DB_BACKUP_RETENTION` 对齐成该计划的值 |
| 重新部署时报 Secret 已存在 | Secrets Manager 有 30 天恢复期。`99-destroy.sh` 第 8 步会强制清理；单独清理见该脚本 |
| Pod 起不来报没 IP | 私有子网 IP 耗尽。`01-preflight.sh` 第 9 项给容量估算；可给 VPC 加辅助 CIDR（如 `100.64.0.0/16`）或开启 vpc-cni 前缀委派（`30-eks-addons.yaml` 的 `EnablePrefixDelegation`） |

### kubectl 连不上集群的三种原因

这三种的错误特征和补救措施完全不同，最容易误判。`03` / `04` 脚本里的 `setup_kubeconfig` 会自动归类并打印对应修复命令，同时并排显示「集群实际端点 vs kubeconfig 端点」。

| 错误特征 | 原因 | 修复 |
|---|---|---|
| `dial tcp: lookup ...: no such host` | kubeconfig 指向**已删除的集群**。同名集群重建后最容易踩：context 名完全一样（都是 `arn:aws:eks:...:cluster/<name>`），肉眼看不出端点变了 | `aws eks update-kubeconfig --region <region> --name <cluster>` |
| `dial tcp [::1]:8080: connect: connection refused` | 当前**没有 kubeconfig**，kubectl 退化到默认的 `localhost:8080` | 同上 |
| `i/o timeout` / `context deadline exceeded` | 出口 IP 不在公共端点白名单里（CloudShell 的 IP 会轮换） | `./scripts/allow-my-ip.sh`；`FIX_API_WHITELIST=auto` 时脚本会自动追加 |
| `Unauthorized` / `403` | 网络通但鉴权失败，当前 IAM 身份没有集群访问权限 | 配 `ADMIN_PRINCIPAL_ARN` 后重新部署 cluster 栈，或手工创建 Access Entry |

手工快速判断：

```bash
aws eks describe-cluster --name <cluster> --query 'cluster.endpoint' --output text   # 集群实际端点
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'             # kubeconfig 端点
curl -s https://checkip.amazonaws.com                                               # 当前出口 IP
aws eks describe-cluster --name <cluster> \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text               # 白名单
```

常用命令：

```bash
# 节点组事件
aws eks describe-nodegroup --cluster-name sharetronic-eks --nodegroup-name ng-general \
  --query 'nodegroup.health'

# 栈失败原因
aws cloudformation describe-stack-events --stack-name <stack> \
  --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table

# 登录 Nacos 实例
aws ssm start-session --target $(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names sharetronic-test-nacos-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
```

---

## 8. 成本估算（ap-southeast-1，按需价，仅供参考）

| 项 | 规格 | 约 / 月 (USD) | `INSTALL_NACOS=false` 时 |
|---|---|---|---|
| EKS 控制面 | 1 集群 | 73 | 73 |
| 工作节点 | m7i.large × 2 | 190 | 190 |
| 节点 EBS | gp3 80 GiB × 2 | 16 | 16 |
| NAT 网关 | 1 个 + 数据处理 | 35+ | 35+ |
| CloudWatch Logs | 控制面（+ Nacos） | 10~30 | 10~20 |
| Nacos EC2 | m7g.large × 1 | 76 | — |
| Nacos EBS | gp3 50 GiB | 5 | — |
| RDS MySQL | db.t4g.medium 单 AZ + 50 GiB gp3 | 70 | — |
| 内网 NLB | 1 个 | 20+ | — |
| **合计** | | **约 500 / 月** | **约 350 / 月** |

可选扩展「跳板 / 构建机」另计：m7i.large 约 **$95** + gp3 100 GiB 约 $10 + 公网 IPv4（EIP）约 $3.6，合计约 **$109 / 月**（ECR 存储另按 $0.10/GB·月）。不用时 `./scripts/50-bastion.sh destroy` 删除即可（仅停机仍会收 EBS 和 EIP 的费用）。

降本方向：节点组改 Graviton（m7g，省约 20%）、节点用 SPOT、RDS 买 Reserved Instance、控制面日志只留 `audit` + `authenticator`。

---

## 9. 交付演练记录（2026-09-21）

本交付包已在交付方的测试账号（`ap-southeast-1`，已有 VPC 场景）上完整跑通一遍，`04-verify.sh --all` 结果 **34 项通过 / 0 失败**。

在你自己的账号部署后，建议同样执行 `./scripts/04-verify.sh --all`，把结果与下表对照，并连同 Account ID / 区域 / VPC ID 一起存档作为验收记录：

```bash
aws sts get-caller-identity --query Account --output text   # 你的 AWS Account ID
./scripts/04-verify.sh --all 2>&1 | tee verify-$(date +%Y%m%d).log
```

实测确认的关键结果：

| 验证项 | 结果 |
|---|---|
| 5 个 CloudFormation 栈 | 全部 `CREATE_COMPLETE` |
| EKS 控制面 | 1.36（platform `eks.13`），public+private 端点，5 类控制面日志，KMS 信封加密 |
| 节点 | 2 × m7i.large AL2023，`v1.36.4-eks`，containerd 2.2.7 |
| 6 个托管 Addon | 全部 `ACTIVE`，kube-system 内 0 个异常 Pod、0 次重启 |
| Pod Identity | ALB Controller Pod 已注入 `AWS_CONTAINER_CREDENTIALS_FULL_URI` |
| EBS CSI + gp3 | PVC 动态供给 + 挂载成功；gp3 为唯一默认 SC |
| ALB Controller | 自建 Ingress → ALB 落在公有子网，`target-type: ip` 直连 Pod IP，HTTP 200 |
| Cluster Autoscaler | 自动发现到托管节点组 ASG（2/2/6） |
| Nacos 2.3.2 | 冒烟 9 项全通过：DNS / readiness / 鉴权登录 / **匿名请求被拒 403** / 发布配置 / 读回配置 / 注册实例 / 查询实例 / 9848 gRPC 可达 |
| Nacos 持久化 | RDS 里 13 张 Nacos 表，数据源为 MySQL（非 Derby），默认口令已被覆盖，`nacos.service` active |

演练中真实踩到并已固化进脚本的问题：

1. **VPC `enableDnsHostnames=false`** —— 节点 22 分钟无法注册，`health.issues` 全程为空。已加入 preflight 硬检查 + 建集群前自动修复（`FIX_VPC_DNS`）。详见第 2 节①。
2. **私有子网默认路由 blackhole** —— 已加入自动清理残留路由 + 自动建 NAT（`CREATE_NAT_GATEWAY=auto`）。详见第 2 节②。
3. **AMI 不能用 `{{resolve:ssm:/aws/service/...}}`** —— 测试账号的 SSO 角色被组织策略（SCP）禁止读 `/aws/` 命名空间的 SSM 公共参数。启用了类似 SCP 的企业账号都会遇到，所以改为脚本用 `describe-images` 解析后传参，不依赖该权限。
4. **AWS Backup 计划会改写 RDS 备份配置** —— 测试账号里已有的 Backup 计划把保留期从 7 改成 35 天。你的账号若有按标签或资源类型匹配 RDS 的 Backup 计划，会出现同样的情况，排查方法见第 7 节排障表。
5. 验收脚本自身两处缺陷已修：ALB Controller 是 distroless 镜像，不能用 `kubectl exec printenv` 检查 Pod Identity（假阴性）；Nacos 发布配置后需重试才能读到（异步 dump 缓存，约 2 秒）。

---

## 10. 目录结构

```
eks_delivery/
├── config.env                       ← 唯一需要修改的文件
├── README.md
├── docs/
│   ├── jenkins-cicd.md              外部 Jenkins 接入说明（方式一：推 ECR + 部署 EKS；方式二：跳板机构建）
│   └── bastion-upgrade.md           跳板 / 构建机部署 + 现有 Jenkins 配置（傻瓜式步骤）
├── ci/
│   ├── Jenkinsfile.example          示例流水线：构建 → 推 ECR → 部署 EKS
│   ├── Jenkinsfile.bastion-jar.example  示例流水线：上传 JAR → SSH 跳板机构建 → 推 ECR
│   └── sample/                      测试用可执行 JAR（order-service.jar）及源码 Hello.java
├── cloudformation/
│   ├── 05-network-prereq.yaml       NAT 网关（按需）
│   ├── 10-eks-cluster.yaml          EKS 控制面
│   ├── 20-eks-nodegroup.yaml        托管节点组
│   ├── 30-eks-addons.yaml           Addon + 控制器 IAM
│   ├── 40-nacos.yaml                Nacos + RDS + NLB
│   ├── 50-bastion.yaml              可选扩展：公有子网跳板 / 构建机（x86）
│   ├── 55-eks-nodegroup-arm64.yaml  可选扩展：Graviton（arm64）托管节点组，默认带 taint
│   └── 60-ci-ecr.yaml               可选扩展：外部 Jenkins 推 ECR 的 IAM 身份
├── iam/
│   └── aws-load-balancer-controller-iam-policy.json   （官方策略，v3.5.0，已固化）
├── manifests/
│   ├── gp3-storageclass.yaml
│   ├── nacos-smoke-test.yaml        Nacos 端到端冒烟 Job
│   └── ci-deployer-rbac.yaml        Jenkins 部署用 ServiceAccount + 命名空间级 Role
├── scripts/
│   ├── lib.sh                       公共函数（含 kubeconfig 自愈与连通性分类诊断）
│   ├── install-tools.sh             装 kubectl / helm 到 ~/.local/bin
│   ├── bg.sh                        把长任务挂进 tmux，抗断网；--status 快速看进度
│   ├── configure-network.sh         网络配置向导：选 VPC / 公有 / 私有子网，写回 config.env
│   ├── 00-discover.sh               只读的网络详情报告（排查用）
│   ├── 01-preflight.sh              只读预检（网络配置无效时自动进入向导）
│   ├── 02-deploy.sh                 部署全部栈（幂等，可分阶段）
│   ├── 03-post-install.sh           集群内组件
│   ├── 04-verify.sh                 端到端验收（自己写 kubeconfig，不依赖 03）
│   ├── allow-my-ip.sh               更新 API Server 公网白名单
│   ├── 50-bastion.sh                可选扩展：跳板 / 构建机部署 / 验收 / Jenkins 配置 / 删除（独立于 02 / 99）
│   ├── bastion/
│   │   └── build-push-jar.sh        跳板机上的 JAR -> 镜像 -> ECR 工具（由 50-bastion.sh 安装）
│   ├── 55-arm-nodegroup.sh          可选扩展：Graviton 节点组部署 / 验收 / CAS 扩容测试 / 删除（独立于 02）
│   ├── 60-ci-setup.sh               可选扩展：外部 Jenkins 的 ECR 身份 + kubeconfig 交接（独立于 02 / 99）
│   └── 99-destroy.sh                逆序清理
└── tests/
    └── test-55-arm-nodegroup.sh     55 扩展的离线测试（stub aws，不访问 AWS）
```
