#!/system/bin/sh
# service.sh — KSU/Magisk 开机(late_start)拉起核心脚本
MODDIR=${0%/*}
# 清掉上次开机的残留 pidfile(重启后 PID 会被复用, 不清会让守护进程误判已存在)
rm -f /data/adb/p2p144/daemon.pid 2>/dev/null
# 等 system_server 稳定后再应用
( sleep 10; sh "$MODDIR/apply.sh" daemon >/dev/null 2>&1 ) &
