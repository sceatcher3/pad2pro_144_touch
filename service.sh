#!/system/bin/sh
# service.sh — KSU/Magisk 开机(late_start)拉起核心脚本
# v1.4.2: 起守护前(等 10s)再跑一遍 post-fs-data.sh。有的元模块在本脚本之后才叠加
#   /my_product, 会把开机早期的 bind 盖住; 脚本幂等(活文件已对就跳过), 多跑一次只补不坏。
MODDIR=${0%/*}
# 清掉上次开机的残留 pidfile(重启后 PID 会被复用, 不清会让守护进程误判已存在)
rm -f /data/adb/p2p144/daemon.pid 2>/dev/null
# 等 system_server 稳定后再应用
( sleep 10; sh "$MODDIR/post-fs-data.sh" >/dev/null 2>&1; sh "$MODDIR/apply.sh" daemon >/dev/null 2>&1 ) &