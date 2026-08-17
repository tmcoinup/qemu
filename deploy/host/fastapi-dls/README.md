# fastapi-dls Docker Compose 部署

此目录是一套可复制到另一台 Linux 服务器的一键部署文件。运行态数据、私钥、数据库、`.env` 和导出的 token 均已被本目录的 `.gitignore` 排除。

## 快速部署

服务器需要 Docker Engine、Docker Compose v2、OpenSSL 和 curl。将整个目录复制到服务器后执行：

Ubuntu/Debian 可先安装依赖：

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 openssl curl
sudo systemctl enable --now docker
```

```bash
cd fastapi-dls
./dlsctl.sh deploy 192.168.30.127
```

使用域名时：

```bash
./dlsctl.sh deploy dls.example.com 443 443
```

脚本会完成以下操作：

1. 从 `.env.example` 创建权限为 `0600` 的 `.env`。
2. 生成带正确 IP/DNS SAN 的自签 Web TLS 证书。
3. 拉取并启动 `collinwebdesigns/fastapi-dls:2.0.3`。
4. 等待 `/-/health` 通过。
5. 将客户端令牌导出到 `out/client_configuration_token.tok`，权限为 `0600`。

Compose 没有传入 `DEBUG`。这是有意设计：当前 2.0.3 镜像会把非空字符串 `DEBUG=false` 误判为开启调试，省略该变量才能保持关闭。

如果当前用户没有 Docker 权限，可使用 `sudo ./dlsctl.sh ...`。不要通过环境变量或命令行保存 sudo 密码。

## Windows guest 安装 token

在本 QEMU 仓库中，优先使用经过严格校验和失败回滚的授权脚本。若 guest 已启用
WinRM，可从仓库 host 执行：

```bash
./deploy/install-vgpu-license.sh 2 \
  --license-url https://dls.example.com/-/client-token
```

使用本脚本生成的自签证书时额外传 `--insecure-tls`。未启用 WinRM 时，把
`deploy/guest/install-vgpu-license.ps1` 复制到 guest，在管理员 PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\install-vgpu-license.ps1 `
  -LicenseUrl 'https://dls.example.com/-/client-token'
```

自签证书对应参数是 `-InsecureTls`。完整的原子替换、回滚和验收规则见
`deploy/docs/VGPU-LICENSING.md`。下面是脱离本仓库授权脚本时的手工后备方法。

把导出的 `client_configuration_token.tok` 复制到 Windows，然后在管理员 PowerShell 执行：

```powershell
$dst = 'C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\client_configuration_token.tok "$dst\client_configuration_token.tok" -Force
Restart-Service NVDisplay.ContainerLocalSystem -Force
Start-Sleep 15
nvidia-smi.exe -q | Select-String 'Product Name|Driver Version|License Status'
```

使用客户端配置令牌时，NVIDIA 控制面板中的主/次许可证服务器地址和端口保持空白。

也可以从 guest 直接下载；自签证书需要 `-k`：

```powershell
$dst = 'C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
curl.exe -k --fail --silent --show-error `
  https://192.168.30.127/-/client-token `
  -o "$dst\client_configuration_token.tok"
Restart-Service NVDisplay.ContainerLocalSystem -Force
```

## 修改授权地址

`DLS_URL` 只写 IPv4 或 DNS 名，不要写 `https://`、端口或路径。修改地址的推荐命令是：

```bash
./dlsctl.sh set-address dls-new.example.com 443 443
```

该命令会：

- 更新私有 `.env`；
- 只重签 `webserver.key/webserver.crt`，保留内部 DLS CA、签名私钥和租约数据库；
- 重建容器并导出含新地址的 token。

`set-address` 默认生成新的自签 Web 证书。若服务器使用公有 CA/Let's Encrypt 证书，
先运行 `./dlsctl.sh configure <新域名>`，再用匹配新域名的 full chain 和私钥替换
`state/cert/webserver.crt`、`state/cert/webserver.key`，最后运行
`./dlsctl.sh deploy`；证书 SAN 已匹配时脚本不会覆盖它。

地址已经写进 token，旧 token 仍指向旧服务地址。因此地址变化后，必须把新 token
重新安装到每台 guest 并重启 `NVDisplay.ContainerLocalSystem`。推荐重新运行上述
`install-vgpu-license.sh --license-url ...`，让脚本同时验证 `Licensed`、服务状态和
设备管理器 Code 0。

也可以手工编辑 `.env` 后运行 `./dlsctl.sh deploy`；脚本检测到证书 SAN 不匹配时会自动重签 Web 证书。

端口含义：

- `DLS_PORT`：写进客户端 token 的公网/VPN 端口。
- `HOST_PORT`：Docker 在服务器本机映射的端口。
- `LISTEN_ADDRESS`：Docker 绑定的本机 IPv4。建议绑定 VPN/LAN 地址，而不是所有接口。

直接暴露容器时，`DLS_PORT` 与 `HOST_PORT` 应相同。经过反向代理时可以不同，但代理必须把 HTTPS 请求转发到 `HOST_PORT`。

## 复用宿主 Nginx 的 443（多域名 / Cloudflare）

适用于一台服务器已经由宿主 Nginx 占用 `:443`、域名使用 Cloudflare 橙云代理的情况。流程遵循
`auto_clash/docs/multi-site-deployment.md` 的多站点约定：每个应用只发布一个不同的回环端口，
宿主 Nginx 按 `server_name` 分流 80/443，并统一持有对应域名的前端 TLS 证书。

本目录提供 `nginx/install-multisite-proxy.sh` 和 80/443 站点模板。脚本创建**独立**虚拟主机；
Docker 不会监听公网 443，也不会修改其他 Docker Compose 项目、已有域名或 Nginx 的默认 TLS 站点。

```text
vGPU guest
  -> https://dls.example.com:443
  -> Cloudflare
  -> 宿主 Nginx :443
  -> https://127.0.0.1:9443
  -> fastapi-dls Docker
```

这里的三个地址/端口不要混淆：

| 项目 | 含义 | 本例值 |
| --- | --- | --- |
| `DLS_URL` | 写入 token、由 guest 实际访问的 DNS 名 | `dls.example.com` |
| `DLS_PORT` | 写入 token 的公网端口 | `443` |
| `HOST_PORT` | Docker 仅在宿主机本地监听的端口 | `9443` |
| `LISTEN_ADDRESS` | Docker 的本机绑定地址 | `127.0.0.1` |

因此 `deploy` 要求 IP/DNS 名：它不能猜测反代/NAT 之外 guest 真正访问的入口，且该地址还会写进
客户端 token 和 DLS 上游证书的 SAN。地址改变后必须重签并重新下发 token。

### 一次性傻瓜部署

前提：

- 为 `dls.example.com` 创建指向本机源站 IP 的 Cloudflare DNS 记录并打开橙云；
- Cloudflare 的 SSL/TLS 模式为 **Full (strict)**；
- Nginx 已加载一个在 `http` 上下文定义 `$origin_from_cloudflare` 的 Cloudflare real-IP 配置。
  当前服务器上的 `00-cloudflare-realip.conf` 就是可复用的模式；
- 443 已由 Nginx 监听；不要把 Docker 的 `HOST_PORT` 设为 443；
- 有 root/sudo 权限，以及覆盖该域名的 Cloudflare Origin CA 证书或 DNS-01 签发的公开 CA 证书。

首次执行以下命令。将域名、端口和前端证书路径替换为实际值。

```bash
cd /app/qemu/deploy/host/fastapi-dls

# 先生成私有 .env 和 DLS 上游证书，但暂不启动容器。
./dlsctl.sh configure dls.example.com 443 9443

# 让 DLS 只接受宿主 Nginx 的本机转发，不暴露 9443 到公网。
sed -i 's/^LISTEN_ADDRESS=.*/LISTEN_ADDRESS=127.0.0.1/' .env

# 启动 DLS 并导出权限为 0600 的 token。
./dlsctl.sh deploy

# 写入独立的 80/443 vhost，Nginx 统一拥有公网 443。
sudo ./nginx/install-multisite-proxy.sh install dls.example.com 9443 \
  /etc/nginx/ssl/example/dls.example.com.origin.pem \
  /etc/nginx/ssl/example/dls.example.com.origin.key
```

脚本会校验证书 SAN、DLS 上游证书 SAN 和 Nginx 语法，再平滑加载配置。为避免覆盖已有站点，
若同名 `/etc/nginx/conf.d/dls.example.com.conf` 已存在，脚本会停止。Nginx 会校验
`state/cert/webserver.crt` 中的 DLS 上游 TLS 证书，而不会关闭到 Docker 上游的 TLS 校验。
使用本节的反代模式时，不要把 Cloudflare/公开 CA 的前端证书覆盖到 `state/cert/`；该目录继续
保存 DLS 自签上游证书和内部签名材料，前端证书只由宿主 Nginx 使用。

### 证书：Cloudflare Origin CA（推荐）或 DNS-01

由于源站会拒绝绕过 Cloudflare 的直连，不能依赖 HTTP-01。推荐在 Cloudflare Dashboard 的
**SSL/TLS → Origin Server → Create Certificate** 创建覆盖 `dls.example.com` 的 Origin CA
证书，再通过受控的 SFTP/SCP 或安全终端放到服务器的 root-only 目录，例如：

```text
/etc/nginx/ssl/example/dls.example.com.origin.pem   证书，0644
/etc/nginx/ssl/example/dls.example.com.origin.key   私钥，0600
```

不要把 Origin CA 私钥、Cloudflare API Token 或任何宿主机凭据放入仓库、`.env`、命令历史或
聊天记录。Cloudflare SSL/TLS 必须保持 **Full (strict)**。

若必须使用公开 CA，请使用 DNS-01，而不是 HTTP-01。一个受控终端上的示例为：

```bash
sudo apt-get update
sudo apt-get install -y certbot python3-certbot-dns-cloudflare
sudo install -d -m 0700 /root/.secrets/certbot
sudoedit /root/.secrets/certbot/cloudflare.ini
# 在 sudoedit 中仅写入：dns_cloudflare_api_token = <受限 DNS 编辑 Token>
sudo chmod 0600 /root/.secrets/certbot/cloudflare.ini
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
  -d dls.example.com
sudo ./nginx/install-multisite-proxy.sh install dls.example.com 9443 \
  /etc/letsencrypt/live/dls.example.com/fullchain.pem \
  /etc/letsencrypt/live/dls.example.com/privkey.pem
```

部署后的验收：

```bash
cd /app/qemu/deploy/host/fastapi-dls
./dlsctl.sh status
sudo ./nginx/install-multisite-proxy.sh status 9443
curl --fail --silent --show-error https://dls.example.com/-/health
```

不要输出、提交或通过不安全聊天渠道发送 `out/client_configuration_token.tok`。将它仅通过受控渠道
传给 guest，或让 guest 按本文前述的授权安装脚本从该域名下载。

### 同一张证书为 VMate 增加 `gvmates.com`

如果 VMate 已经通过 `vmate.dgamef.com` 访问，并且要把顶级域名 `gvmates.com` 也转发到同一个
VMate 容器，请新建一个**独立**站点，而不是修改 `vmate.dgamef.com.conf`。Nginx 按 TLS SNI 和
`server_name` 选择证书；`dgamef.com` 的证书不能替代覆盖 `gvmates.com` 的证书。现有 VMate 网关
应继续只监听回环端口（本机默认是 `127.0.0.1:3001`）。

以下命令将保留 `vmate.dgamef.com` 原样，并新建
`/etc/nginx/conf.d/gvmates.com.conf`。其中证书必须同时包含 `gvmates.com`（可同时包含
`*.gvmates.com`），Cloudflare DNS 应为橙云且源站指向本机的指定公网 IP：

```bash
cd /app/qemu/deploy/host/fastapi-dls

# Origin CA 公钥可读，私钥只能由 root 读取。
sudo chmod 0644 /etc/nginx/ssl/gvmates.com/gvmates.com.origin.pem
sudo chmod 0600 /etc/nginx/ssl/gvmates.com/gvmates.com.origin.key

# 单独安装 gvmates.com -> VMate 网关的 80/443 vhost。
sudo ./nginx/install-vmate-domain-alias.sh install gvmates.com 3001 \
  /etc/nginx/ssl/gvmates.com/gvmates.com.origin.pem \
  /etc/nginx/ssl/gvmates.com/gvmates.com.origin.key

# 验证本机网关、Nginx 和公网域名。
sudo ./nginx/install-vmate-domain-alias.sh status 3001
curl -I --max-time 15 https://gvmates.com/
```

该安装器使用与原 VMate 站点相同的 WebSocket、超时、Cloudflare 源站保护和 API 禁止缓存规则，
但 map 变量独立命名，因此不会与已有多域名配置冲突。若目标配置已经存在，安装器会拒绝覆盖。
需要变更时，先备份并审查现有站点，再按本机的变更流程处理。

直接访问源站 IP 的 `:443` 仍会被默认 Nginx 站点拒绝，这是预期的安全行为；应通过
`https://gvmates.com` 或 `https://dls.gvmates.com` 访问。Cloudflare SSL/TLS 模式必须保持
**Full (strict)**。

### 安全收口

该 Nginx 模板会拒绝绕过 Cloudflare 的源站直连，但 Cloudflare 域名本身仍可被互联网访问；这不等于
限制 vGPU guest。fastapi-dls 的管理与租约接口不应对任意公网开放。上线前必须在云防火墙、VPN 或
Cloudflare WAF/Access 中仅允许受控 guest 网段访问 `dls.example.com`。不要把 `9443` 配置为公网端口。

如果运行 `set-address` 改了域名，先为新域名准备覆盖 SAN 的前端证书，再以新域名重建 DLS，最后
运行 Nginx 安装命令并把新 token 安装到所有 guest：

```bash
./dlsctl.sh set-address dls-new.example.com 443 9443
sudo ./nginx/install-multisite-proxy.sh install dls-new.example.com 9443 \
  /secure/cert.pem /secure/key.pem
```

## 日常命令

```bash
./dlsctl.sh status
./dlsctl.sh token                         # 重新导出默认 token
./dlsctl.sh token /secure/path/client.tok # 导出到指定路径
./dlsctl.sh restart
./dlsctl.sh logs
./dlsctl.sh down
./dlsctl.sh up
sudo ./nginx/install-multisite-proxy.sh status 9443
```

## 数据、安全与迁移

以下内容必须成组备份，并使用加密存储：

```text
state/cert/       DLS 内部 CA、签名私钥和 Web TLS 证书
state/database/   SQLite 租约数据库
.env              服务地址和部署参数
```

不要提交或公开 `state/`、`.env`、`out/` 和 `*.tok`。如果遗失 `state/cert` 中的内部签名材料，新实例会生成另一套身份，所有 guest 都需要重新下发 token。

fastapi-dls 的管理和租约接口没有面向公网的登录保护。不要将 443 端口无限制暴露到互联网；应使用 VPN、安全组或主机防火墙，只允许受控 guest 网段访问。服务器与 guest 都应启用 NTP，避免时钟偏差造成 token 或租约校验失败。

从旧的 `/opt/fastapi-dls` 迁移时，先停止旧容器，再把旧的 `cert/` 和 `data/` 内容分别复制到 `state/cert/` 与 `state/database/`。保持私钥文件仅管理员可读，然后运行 `./dlsctl.sh deploy <现有地址>`。不要在两个实例上同时复用同一个 SQLite 数据库目录。

上游项目与兼容性说明：<https://git.collinwebdesigns.de/oscar.krause/fastapi-dls>
