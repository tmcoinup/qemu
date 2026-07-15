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

## 日常命令

```bash
./dlsctl.sh status
./dlsctl.sh token                         # 重新导出默认 token
./dlsctl.sh token /secure/path/client.tok # 导出到指定路径
./dlsctl.sh restart
./dlsctl.sh logs
./dlsctl.sh down
./dlsctl.sh up
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
