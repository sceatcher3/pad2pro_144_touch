#!/system/bin/sh
# service.sh — KSU/Magisk 开机(late_start)拉起核心脚本
# v1.6.0: 同时拉起触控守护(apply.sh guard); 清 guard.pid 残留
# v1.5.0: 删掉 late_start 补跑 post-fs-data.sh —— 它只为旧版 bind 兜底服务;
#   现在挂载完全交给元模块(合并在 post-fs-data 阶段已完成), 副本也已在开机早期生成。
MODDIR=${0%/*}
# 清掉上次开机的残留 pidfile(重启后 PID 会被复用, 不清会让守护进程误判已存在)
rm -f /data/adb/p2p144/daemon.pid /data/adb/p2p144/guard.pid 2>/dev/null
# 等 system_server 稳定后再应用
( sleep 10; sh "$MODDIR/apply.sh" daemon >/dev/null 2>&1 ) &
# 触控守护晚 2 秒起, 与刷新看门狗分开进程(单职责)
( sleep 12; sh "$MODDIR/apply.sh" guard >/dev/null 2>&1 ) &