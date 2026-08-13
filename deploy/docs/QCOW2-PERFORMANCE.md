# qcow2 读写性能

VMate 的磁盘性能策略与 Guest 显示的 Samsung、Intel、WD 或 KIOXIA
型号无关。型号属于客体硬件身份；下述参数只控制 Linux 宿主的
qcow2/BlockBackend 路径。

## 启动时自动策略

`start-vm.sh` 每次启动会使用真实 O_DIRECT 读取依次探测
`io_uring → native → threads`，并把通过的后端送入：

```text
cache=none,aio=<auto-selected>,discard=unmap,detect-zeroes=unmap
l2-cache-size=67108864,refcount-cache-size=8388608
cache-clean-interval=0,discard-no-unref=on
```

- 64 MiB L2 cache 与 8 MiB refcount cache 在当前布局下都覆盖
  512 GiB；镜像虚拟容量为 `512110190592` bytes，因此不需要运行期
  驱逐元数据页。
- `discard-no-unref=on` 保留 qcow2 cluster 映射，减少重复释放/分配造成的
  文件尾增长和元数据碎片；`discard=unmap` 仍向宿主文件层传递回收。
- 不给 emulated NVMe 添加 IOThread；当前 NVMe DMA helper 要求 BlockBackend
  保留在主 AioContext。
- 不默认启用 `lazy_refcounts`；它会把写入优势换成宿主异常断电后的
  refcount 全表重建。

## 新镜像布局

新建独立盘和 clone overlay 统一使用：

```text
compat=1.1,cluster_size=131072,extended_l2=on
preallocation=metadata,lazy_refcounts=off
```

128 KiB cluster 的 Extended L2 会生成 4 KiB subcluster，减少带 backing
增量盘遇到 4 KiB 小写入时的 COW 放大。元数据预分配会让 `stat`
看到的表观文件长度接近虚拟容量，但它仍是稀疏文件；实际占用应用
`du -h disk.qcow2` 查看。

## 已有实例离线优化

先在 Guest 内正常关机，并等待 QEMU 退出：

```bash
# 单个实例
deploy/scripts/optimize-qcow2.sh 1

# 全部数字实例
deploy/scripts/optimize-qcow2.sh --all

# 需要人工回滚窗口时保留原盘（会约双倍占用）
deploy/scripts/optimize-qcow2.sh 1 --keep-backup
```

工具会按实例串行执行：

1. 取得与 start/stop 相同的生命周期锁，并检查 QEMU/lsof 占用。
2. 校验源 qcow2，拒绝会在转换中丢失语义的内部快照、persistent bitmap
   或 external data file。
3. 在同目录临时文件中转换，保持原 backing 链。
4. 运行 `qemu-img check` 和逻辑内容对比；全部通过后才原子替换。
5. 默认在成功校验后删除该次临时回滚硬链接；中断时自动恢复原盘。

转换期间会暂时需要约等于当前实际镜像占用的额外空间。工具会在开始前
保留 20% 转换波动和 16 GiB 安全余量，不允许用强制参数越过。
