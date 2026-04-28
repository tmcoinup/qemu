# NVIDIA vGPU 驱动手动安装（多 GPU profile 支持）

本文档覆盖 guest 里的 NVIDIA 驱动如何手动装 + 不同 `GPU_PROFILE` 随机到 `gtx1050_2gb` / `gt1030_2gb` 时的处理方式。

---

## 0. 目录速查

| 场景 | 命令 |
|---|---|
| VM 配置到 **GT 1030** | `install-patched-driver.ps1`（下 Display.Driver.zip 时里面 INF 已包含 DEV_1D01） |
| VM 配置到 **GTX 1050** | `install-patched-driver.ps1` 改参 or 用 `inf-patch.ps1 -Profile gtx1050_2gb` 动态 patch |
| Approach A 切回 B | `switch-to-approach-b.ps1 -TargetName 'GeForce GT 1030'` |
| 不确定 VM 当前是什么 profile | `cat /home/ubuntu/images/vms/configs/vm1.conf \| grep GPU_` |

---

## 1. 驱动源文件在哪

**宿主**：

```
~/Downloads/
├── nvgpu_NVIDIA-GRID-Ubuntu-KVM-535.161.05-535.161.07-538.33.zip     ← host 535 + guest 538.33 GeForce
├── vGPU17.6/
│   ├── Host_Drivers/NVIDIA-Linux-x86_64-550.163.01-grid.run
│   └── Guest_Drivers/553.74_grid_win10_win11_server2022_dch_64bit_international.exe
```

两条路线（二选一）：
- **A = 538.33 GeForce driver**（本项目当前用的）— 通过 vGPU-Unlock-patcher 跑在 535 host 上，guest 里用真正的 GeForce Desktop 驱动，无 GRID 字串
- **B = 553.74 GRID driver** — 官方 vGPU 17.6 配套驱动，guest 里是 Quadro/GRID 驱动

**Guest 里的驱动包** (被 `install-patched-driver.ps1` 解压出来的):

```
C:\nv\538.33-orig\       ← 原版 Display.Driver, 签名 = Microsoft Windows Hardware Compatibility Publisher
C:\nv\538.33-patched\    ← INF 加了 DEV_1D01 / DEV_1C81 的 patched 版
C:\nv\nvgridsw.CAT.new   ← 自签 cat (approach A 时)
```

---

## 2. HTTP 服务器（宿主发 zip 给 guest）

`install-patched-driver.ps1` 里硬编 `http://192.168.30.127:8080/Display.Driver.zip`。宿主要先把这个起来：

```bash
cd /home/ubuntu/images/staging              # 放 Display.Driver.zip 的目录
python3 ~/projects/qemu/deploy/server.py   # 监听 0.0.0.0:8000 (注意端口)
# 或简单:
python3 -m http.server 8080
```

⚠️ server.py 默认端口是 **8000**，install-patched-driver.ps1 里写的是 **8080** — 要么改脚本的 port 要么改 URL。最省事：

```bash
cd /home/ubuntu/images/staging && python3 -m http.server 8080
```

`Display.Driver.zip` 是 538.33 解压后 `Display.Driver` 文件夹的 zip 包（包含 `nvgridsw.inf`, `nvlddmkm.sys`, `nvwgf2umx.dll` 等）。本机已生成过这个 zip：

```bash
ls /home/ubuntu/images/staging/Display.Driver.zip     # 应该有
# 没有的话: cd ~/Downloads/vGPU17.6/Guest_Drivers/ && mkdir /tmp/ex && cd /tmp/ex && \
#           7z x 553.74_grid_*.exe && zip -r Display.Driver.zip Display.Driver/ && \
#           mv Display.Driver.zip /home/ubuntu/images/staging/
```

---

## 3. Approach A 手动安装步骤（guest 里）

### 3.1 准备

```powershell
# 1. 创建工作目录
New-Item -Type Directory -Force C:\nv | Out-Null

# 2. 把宿主的 install-patched-driver.ps1 拉进来
Invoke-WebRequest 'http://192.168.30.127:8080/install-patched-driver.ps1' -OutFile C:\nv\install-patched-driver.ps1

# 3. 跑它（管理员 PowerShell）
cd C:\nv
powershell -ExecutionPolicy Bypass -File .\install-patched-driver.ps1
```

脚本做的事：
1. 关 `testsigning`、`nointegritychecks`（本项目用合法签名链，**不需要测试模式**）
2. 下载 `Display.Driver.zip` → 解压到 `C:\nv\538.33-patched\`
3. 生成自签证书 `CN=NVIDIA Corporation`，导入到 `Root` + `TrustedPublisher` 两个 store
4. 重新生成 `nvgridsw.cat`（New-FileCatalog），用自签证书签名
5. 卸载旧 oem INF（pnputil /delete-driver /uninstall /force）
6. 装 patched INF（pnputil /add-driver /install）
7. 重启

### 3.2 关于"测试签名模式"

本项目**不需要开 testsigning**。因为：
- 我们的自签证书被放进了 `LocalMachine\Root`（让 Windows 信任根）
- 也放进了 `LocalMachine\TrustedPublisher`（避免装驱动时弹信任对话框）
- `nvgridsw.cat` 用这个证书签名 → 链路 cat → Root 可信 → Windows 允许 load driver

testsigning 是用于**没有有效签名链**时的 bypass。我们有合法链路（自签但 trusted），所以**关闭 testsigning 能正常工作**。脚本 step 1 里也显式 `bcdedit /set testsigning off` 以避免右下角水印。

验证：

```powershell
bcdedit | Select-String testsigning
# 应该没有，或显示 "testsigning No"
```

### 3.3 处理 GPU profile = gtx1050_2gb

`install-patched-driver.ps1` 默认的 `Display.Driver.zip` 只 patch 了 **DEV_1D01 (GT 1030)**。如果 `create-vm.sh` 给你的 VM 分到了 `gtx1050_2gb` profile，有两个办法：

**办法 1：改宿主侧 zip（推荐，一次改了所有 VM 复用）**

```bash
cd /home/ubuntu/images/staging
unzip Display.Driver.zip -d /tmp/ex && cd /tmp/ex/Display.Driver
# 编辑 nvgridsw.inf，在 [Strings] 和 [NVIDIA_Devices.NTamd64.*] 里加:
#   NVIDIA_DEV.1C81 = "NVIDIA GeForce GTX 1050"
#   %NVIDIA_DEV.1C81% = Section400, PCI\VEN_10DE&DEV_1C81
# 同时保留 1D01 的条目，zip 就能同时支持 1030 和 1050
zip -r Display.Driver.zip Display.Driver/
cp Display.Driver.zip /home/ubuntu/images/staging/
```

**办法 2：用 `guest/spoof-inf/inf-patch.ps1` 在 guest 里动态 patch（给现有驱动追加 DeviceID）**

```powershell
# 先用 install-patched-driver.ps1 装好基础驱动（哪怕是 1030 的 INF）
# 然后:
C:\nv\spoof-inf\inf-patch.ps1 -Profile gtx1050_2gb `
    -DriverRoot 'C:\nv\538.33-patched'
# 它会:
# 1) 在 nvdm*.inf 的 [Strings] 里追加 NVIDIA_DEV.1C81 = "NVIDIA GeForce GTX 1050"
# 2) 在 [NVIDIA_Devices.NTamd64.*] 追加 DEV_1C81 条目
# 3) pnputil /delete-driver 旧 oem + /add-driver 新 INF
```

两个脚本都在 `deploy/guest/spoof-inf/` 下。

### 3.4 create-vm.sh 里锁定 profile

如果不想让它随机到 1050，改 `deploy/create-vm.sh` 里的池子：

```bash
GPU_PROFILES=(gt1030_2gb)     # 只留 1030
```

然后 `./create-vm.sh N` 生成的 vmN.conf 就永远是 1030。

---

## 4. Approach B 手动安装步骤

approach B 用 NVIDIA **原厂签名**的 nvgridsw.inf，PCI 保留 DEV_1E30 (Quadro RTX 6000 真 ID)。

先决：宿主必须用 `--no-spoof` 启动（VM PCI 保持 DEV_1E30）：

```bash
cd ~/projects/qemu/deploy
OVMF_CODE=host/OVMF_CODE_4M_stealth.fd GPU_SPOOF=0 ./start-vm.sh 1
./connect.sh 1
```

guest 里：

```powershell
cd C:\nv
powershell -ExecutionPolicy Bypass -File .\switch-to-approach-b.ps1 `
    -TargetName 'GeForce GT 1030'
shutdown /r /t 5
```

脚本会：
1. 清 `CN=vGPU-Patch-Signer` 和 `CN=NVIDIA Corporation` 自签证书
2. 卸载 approach A 的 oem INF
3. 装原版 `C:\nv\538.33-orig\nvgridsw.inf`（Microsoft 官方签名）
4. 跑 `patch-grid-strings.ps1 -TargetName 'GeForce GT 1030'` 改注册表字串（GRID RTX6000-* → GeForce GT 1030）
5. 重启

---

## 5. 后续管理

**验证当前 approach**：

```powershell
# 活跃 Display + 签名
Get-PnpDevice -Class Display -PresentOnly:$true | Format-Table
$fr = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' `
    -Filter 'nvgridsw.CAT' -Recurse | Select-Object -First 1
Get-AuthenticodeSignature $fr.FullName | Format-List Status, SignerCertificate
```

看到 `CN=Microsoft Windows Hardware Compatibility Publisher` = approach B。
看到 `CN=NVIDIA Corporation` = approach A。

**清 RDP 幽灵条目（每次 session 重连后跑）**：

```powershell
C:\nv\purge-rdp-ghosts.ps1              # 一次性清
C:\nv\purge-rdp-ghosts.ps1 -Install    # 注册 SYSTEM 计划任务 (事件 21/23/24/25 触发)
```

**切换方案**：approach A ↔ B 可以反复切，每次切完必须重启 guest。

---

## 6. 故障快查

| 症状 | 可能原因 | 解决 |
|---|---|---|
| pnputil /add-driver 报 "无效数字签名" | 自签证书没进 TrustedPublisher | 重跑 install-patched-driver.ps1 step 4 |
| Device Manager 里 NVIDIA 有叹号 Error 43 | INF 匹配了 DEV_1E30 但 PCI 是 DEV_1D01 | 宿主 `--no-spoof` 或 guest 重装 approach A 装 DEV_1D01 匹配的 patched INF |
| 装完驱动进不了桌面 / bootmgr 卡 spinner | Fast Startup 存了不兼容的 hiberfile | `./stop-vm.sh --force` 后 mount qcow2 删 hiberfil.sys（见 memory `project_windows_boot_hang_recovery`）|
| `install-patched-driver.ps1` 下载 zip 失败 | 宿主 HTTP 没起 | `cd /home/ubuntu/images/staging && python3 -m http.server 8080` |
