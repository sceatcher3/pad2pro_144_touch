#!/system/bin/sh
# probe2.sh — 只读探针: ColorOS 刷新率策略文件 + 触控 IRQ 真名
# KSU 终端运行:  sh /sdcard/Download/Code/Module/probe2.sh
LOG=/sdcard/Download/p2p_probe2.txt
: >"$LOG"
out(){ echo "$*"; echo "$*" >>"$LOG"; }

out "===== /my_product/etc 刷新率相关文件 ====="
ls -la /my_product/etc/ 2>&1 | grep -iE 'refresh|vrr|frame|fps|lcm' >>"$LOG"
out "===== refresh_rate_config.xml ====="
cat /my_product/etc/refresh_rate_config.xml >>"$LOG" 2>&1
out "===== oplus_vrr_config.json ====="
cat /my_product/etc/oplus_vrr_config.json >>"$LOG" 2>&1
out "===== sys_dynamic_frame_config.xml ====="
cat /my_product/etc/sys_dynamic_frame_config.xml >>"$LOG" 2>&1
out "===== /proc/interrupts 全文前80行 ====="
head -n 80 /proc/interrupts >>"$LOG" 2>&1
out "===== 触控相关中断行(宽松匹配) ====="
grep -iE 'touch|tp_|nt36|novatek|goodix|fts|spi0' /proc/interrupts >>"$LOG" 2>&1
out "===== 完, 文件在 $LOG ====="
