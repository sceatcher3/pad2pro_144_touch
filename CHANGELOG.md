# 更新日志

## v1.3.3 (versionCode 6)
- 挂载路线定稿: 交由 Hybrid Mount 以 OverlayFS 模式自动合并模块内 my_product/ 策略覆盖, 脚本不再手动 mount
- post-fs-data.sh 改为每次开机从当前原件刷新覆盖副本(OTA 自适应, sed 幂等)
- 手动 bind-mount 保留为无元模块环境的兜底开关(POLICY_OVERLAY=1, 默认关闭)

## v1.3.2 (versionCode 5)
- 恢复手动 bind-mount 兜底: /my_product 与 /mnt/vendor 双视图 + mountinfo 防重复 + 挂后验证
- README 增加 Hybrid Mount 元模块配合说明

## v1.3
- 尝试 KSU 原生挂载 my_product(实测 ResukiSU 不挂非标分区目录, 未生效, 由 v1.3.2 修复)

## v1.2
- 新增 post-fs-data.sh: 备份原件 + sed 生成策略覆盖副本 + bind-mount
- 触控 IRQ 匹配修正(实际中断名为 touch-00, 改 grep touch)
- 看门狗漂移比较改整数, 消除 ColorOS 写 120.00001 造成的每 5s 无谓重写

## v1.1
- SurfaceFlinger 1035 强切(mode 6=144Hz)升为主机制
- 修复看门狗 pidfile 被复用导致守护进程静默退出的问题(alive() 校验 /proc/<pid>/cmdline)

## v1.0.0
- 首发: settings 三重锁(peak/min/oplus 键) + user-preferred display mode + game_switch_enable 触控通道 + 触控 IRQ 绑大核 + 5s 亮屏看门狗
