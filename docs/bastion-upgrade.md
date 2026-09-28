# 跳板 / 构建机（x86）部署 + Jenkins 配置

**效果**：现有 Jenkins 上传 JAR → SSH 到跳板机 → 跳板机 `docker build` → 推送 ECR → 跳板机 `kubectl` 发布到 EKS。

| 项 | 取值（脚本默认，无需配置） |
|---|---|
| 机型 | `m7i.large`（x86_64，2 vCPU / 8 GiB） |
| 磁盘 | 100 GiB gp3 加密 |
| 公网 IP | 弹性 IP（重启不变） |
| 访问 EKS | 经集群私有端点；kubectl 已配好（集群管理员） |
| 推 ECR | 实例角色授权，Jenkins 上**不需要** docker / aws CLI / AWS 密钥 |
| 费用 | 约 $109/月 |

> 不修改 EKS 集群、节点组、Nacos 等已有栈，不需要重跑 01–04 脚本。

---

## 第 1 步：CloudShell 里放入更新包

CloudShell 右上角 **操作 → 上传文件**，选择 `eks_delivery-bastion-x86-upgrade.zip`，然后执行：

```bash
cd ~ && unzip -o eks_delivery-bastion-x86-upgrade.zip && cd ~/eks_delivery && chmod +x scripts/*.sh scripts/bastion/*.sh
```

更新包不含 `config.env`，不会覆盖已有配置。

## 第 2 步：部署跳板机（约 8 分钟）

先在 **Jenkins 服务器**上查出口公网 IP：

```bash
curl -s https://checkip.amazonaws.com
```

然后在 **CloudShell** 执行：

```bash
./scripts/50-bastion.sh
```

脚本只问一个问题：

```
  【需要你填写】Jenkins 服务器的出口公网 IP（会加入跳板机 SSH 白名单）
  Jenkins 出口 IP: 203.0.113.10         ← 填上面查到的 IP
  开始部署？[y/N]                       ← 输入 y
```

其余全部自动：老配置里的 arm 机型 / 30 GiB 自动改为 `m7i.large` / 100 GiB；旧跳板机已被删除时自动清理旧栈重建；SSH 密钥对自动创建，私钥保存到 CloudShell `~/.ssh/<项目>-<环境>-bastion-key.pem`。

结束时自动验收（全部 `OK` 即成功），最后打印第 3 步要用的 **Jenkins 配置**。之后随时可用 `./scripts/50-bastion.sh jenkins` 再打印。

---

## 第 3 步：配置现有 Jenkins（只做一次）

### 3.1 安装插件

**Manage Jenkins → Plugins → Available plugins**，安装（已装的跳过）：

`Pipeline`、`Credentials Binding`、`SSH Credentials`、`File Parameters`

### 3.2 添加凭据（跳板机私钥）

在 CloudShell 执行下面的命令，复制输出的**全部内容**（从 `-----BEGIN` 到 `-----END ...-----`）：

```bash
cat ~/.ssh/*-bastion-key.pem
```

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**：

| 字段 | 填写 |
|---|---|
| Kind | `SSH Username with private key` |
| ID | `bastion-ssh`（必须是这个） |
| Username | `ec2-user` |
| Private Key | 选 **Enter directly** → **Add**，粘贴上面复制的内容 |
| Passphrase | 留空 |

点 **Create**。

### 3.3 添加全局环境变量

**Manage Jenkins → System → Global properties** → 勾选 **Environment variables** → 添加 3 个（值从第 2 步输出里复制）→ **Save**：

| 名称 | 值 |
|---|---|
| `BASTION_HOST` | 跳板机 IP |
| `BASTION_USER` | `ec2-user` |
| `BASTION_HOST_KEY` | 整行复制，形如 `52.x.x.x ssh-ed25519 AAAA...` |

### 3.4 新建流水线

1. **New Item** → 名称填应用名（如 `order-service`）→ 选 **Pipeline** → OK
2. **Pipeline → Definition** 选 `Pipeline script`，粘贴交付包里 `ci/Jenkinsfile.bastion-jar.example` 的全部内容 → **Save**
3. 点一次 **Build Now**：只是让 Jenkins 识别参数，结果为灰色 `NOT_BUILT`，属正常

### 3.5 上传 JAR 构建

点 **Build with Parameters**：

| 参数 | 填写 |
|---|---|
| `APP_JAR` | 选择要发布的 JAR（可执行 jar）。首次测试可用交付包里的 `ci/sample/order-service.jar` |
| `APP_NAME` | 应用名，镜像仓库为 `<项目>/<APP_NAME>`，不存在会自动创建 |
| `JAVA_VERSION` | 17 / 21 / 11 / 8 |
| 其余 | 保持默认 |

点 **Build**，成功后构建描述里就是镜像地址，例如 `<账号>.dkr.ecr.<区域>.amazonaws.com/<项目>/order-service:2`。

> `ci/sample/order-service.jar` 要先从 CloudShell 下载到本地电脑：**操作 → 下载文件**，路径填 `/home/cloudshell-user/eks_delivery/ci/sample/order-service.jar`。

---

## 第 4 步：在跳板机上构建并部署到 EKS（验证 / 手工发布）

在 CloudShell 执行 `./scripts/50-bastion.sh ssm` 登录跳板机，然后切到 `ec2-user`（和 Jenkins 用同一个用户）：

```bash
sudo su - ec2-user
```

### 4.1 准备 JAR（二选一）

**A. 在跳板机上编译示例 JAR**（与 `ci/sample/order-service.jar` 同源；跳板机不需要装 Java，用 JDK 容器编译）：

```bash
mkdir -p ~/demo && cd ~/demo
cat > Hello.java <<'EOF'
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
public class Hello {
  public static void main(String[] a) throws Exception {
    HttpServer s = HttpServer.create(new InetSocketAddress(8080), 0);
    s.createContext("/", x -> {
      byte[] b = ("order-service ok, java " + System.getProperty("java.version") + ", arch " + System.getProperty("os.arch") + "\n").getBytes();
      x.sendResponseHeaders(200, b.length); x.getResponseBody().write(b); x.close();
    });
    s.start();
  }
}
EOF
printf 'Main-Class: Hello\n' > manifest.txt
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/w" -w /w public.ecr.aws/docker/library/eclipse-temurin:17-jdk \
  sh -c 'javac Hello.java && jar cfm order-service.jar manifest.txt Hello*.class'
ls -l order-service.jar
```

**B. 用自己的 JAR**：先在 CloudShell 传到任意 S3 桶（`aws s3 cp ./xxx.jar s3://<桶>/`），再在跳板机上取下来：

```bash
mkdir -p ~/demo && cd ~/demo
aws s3 cp s3://<桶>/xxx.jar ./order-service.jar
```

### 4.2 构建镜像并推送 ECR

```bash
cd ~/demo
build-push-jar --jar ./order-service.jar --app order-service --tag demo-1 --java 17 2>&1 | tee build.log
IMAGE_URI=$(grep '^IMAGE_URI=' build.log | cut -d= -f2-); echo "$IMAGE_URI"
```

输出最后一行形如 `IMAGE_URI=<账号>.dkr.ecr.<区域>.amazonaws.com/<项目>/order-service:demo-1`。Jenkins 构建出的镜像也可以直接把地址赋给 `IMAGE_URI`，跳过 4.1 / 4.2。

### 4.3 部署到 EKS

首次部署（创建命名空间、2 副本 Deployment、Service；重复执行无副作用）：

```bash
kubectl create namespace jenkins-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins-demo create deployment order-service --image="$IMAGE_URI" --port=8080 --replicas=2 --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins-demo expose deployment order-service --port=80 --target-port=8080 --dry-run=client -o yaml | kubectl apply -f -
```

以后发布新镜像：

```bash
kubectl -n jenkins-demo set image deploy/order-service order-service="$IMAGE_URI"
kubectl -n jenkins-demo rollout status deploy/order-service
```

### 4.4 验证访问

```bash
kubectl -n jenkins-demo run curl --rm -i --quiet --restart=Never --image=public.ecr.aws/docker/library/busybox:stable -- sh -c 'sleep 2; wget -qO- http://order-service/'
```

期望输出：`order-service ok, java 17.x, arch amd64`。

不再需要时删除：`kubectl delete namespace jenkins-demo`。

---

## 常见问题

| 现象 | 处理 |
|---|---|
| Jenkins 日志 `Connection timed out` | Jenkins 出口 IP 不对或没填：改 `config.env` 里的 `JENKINS_EGRESS_CIDRS`（多个用逗号分隔），重跑 `./scripts/50-bastion.sh` |
| `Host key verification failed` | 跳板机重建过：执行 `./scripts/50-bastion.sh jenkins`，更新 `BASTION_HOST` / `BASTION_HOST_KEY` |
| `Permission denied (publickey)` | 跳板机重建过、私钥变了：按 3.2 重新粘贴私钥；或 Username 不是 `ec2-user` |
| 没有 Build with Parameters 按钮 | 先点一次 Build Now |
| `没有 JAR` / `No such DSL method 'stashedFile'` | 没装 File Parameters 插件 |
| `MANIFEST 里没有 Main-Class` | 上传了普通 jar（如 `*-plain.jar`），换成可执行的 fat jar |
| `~/.ssh/*-bastion-key.pem` 不存在 | 执行 `./scripts/50-bastion.sh key` 重新取回 |

常用命令（CloudShell）：`./scripts/50-bastion.sh verify`（重新验收）、`jenkins`（重新打印 Jenkins 配置）、`ssm`（登录跳板机）、`key`（取回私钥）、`destroy`（删除跳板机及其密钥对，EKS 与 ECR 镜像不受影响）。

<details>
<summary>附：技术细节（运维参考）</summary>

- **EKS 访问**：集群安全组增加一条「来源 = 跳板机安全组」的入站规则，并为跳板机实例角色创建 EKS Access Entry（集群管理员）。两者归属跳板机栈，`destroy` 时自动撤销。不需要授权时在 `config.env` 设 `BASTION_EKS_ACCESS="none"`。
- **SSH**：22 端口只对 `BASTION_SSH_CIDRS`（默认执行脚本时的出口 IP）+ `JENKINS_EGRESS_CIDRS` 开放；私钥托管在 SSM Parameter Store `/ec2/keypair/<KeyPairId>`，随栈删除。
- **Jenkins 调用方式**：ssh 建临时目录 → `ssh cat >` 上传 JAR → 执行 `build-push-jar`（生成 Dockerfile、`docker build --platform linux/amd64`、推 ECR）→ 删除临时目录；主机指纹严格校验。工作区根目录有 `Dockerfile` 时会一并上传使用。`build-push-jar --help` 查看全部参数。

</details>
