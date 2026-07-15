GTX 1050 vGPU 一键收尾包
========================

1. 必须先“全部解压”这个 ZIP；不要直接在压缩包预览窗口运行。
2. 在宿主 finish-vgpu-install.sh 打开的本地救援 Windows 中，双击
   VgpuGuestFinish.exe，并在 UAC 中选择“是”。
3. EXE 会先校验、签名并把锁定的 538.33 GTX 1050 驱动加入 Driver Store，
   再完成设备名称、休眠、token 和关机。不要手工重启。

成功后宿主才会启用：
  10DE:1C81 / SUBSYS_11C01028
  internal vdev/pdev identity
  per-mdev frl_enabled=0

若任何校验失败，EXE 不写完成回执，也不会自动关机。保留完整错误信息；不要卸载
显示设备。恢复启动可在宿主使用：
  ./deploy/start-vm.sh VM_ID --no-spoof --no-monitor-sync

本 ZIP 内含 DLS token 的 EXE，权限按私有文件处理，不要公开上传或通过 staging
HTTP server 下载。published INF 是每套 Windows 动态分配的 oemN.inf，不应照抄
其他 VM 的编号。
