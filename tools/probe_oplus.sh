#!/system/bin/sh
# ============================================================
# probe_oplus.sh — OnePlus Pad 2 Pro (OPPO Pad 3 Pro) 探针 v1
# 用途: 只读枚举「刷新率 / 触控」相关内核节点与系统状态
# 安全声明: 只执行 cat/ls/getprop/dumpsys/settings get,
#           不写入(echo >)任何节点, 不修改任何设置
# 用法: 把本脚本拷到平板任意路径, KSU 管理器终端执行:
#         su -c sh /路径/probe_oplus.sh
# 输出: /sdcard/Download/pad2pro_probe.txt (跑完发回给 AI)
# ============================================================

OUT="/sdcard/Download/pad2pro_probe.txt"
mkdir -p /sdcard/Download 2>/dev/null
: > "$OUT" 2>/dev/null || OUT="/data/local/tmp/pad2pro_probe.txt"
: > "$OUT" 2>/dev/null || { echo "无法创建输出文件"; exit 1; }

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 2"

sec() { echo "" >>"$OUT"; echo "================ $1 ================" >>"$OUT"; }
p()   { echo "$@" >>"$OUT" 2>&1; }

# 读单个文件: 路径 = 值(前400字节, 换行压平)
rfile() {
  [ -f "$1" ] || return 0
  v=$($TO cat "$1" 2>/dev/null | head -c 400 | tr '\n' ' ')
  [ -z "$v" ] && v="(空或不可读)"
  echo "$1 = $v" >>"$OUT"
}

# 枚举一个目录: 权限列表 + 每个普通文件的内容
rdir() {
  d="$1"
  [ -d "$d" ] || return 0
  sec "目录: $d"
  ls -la "$d" >>"$OUT" 2>&1
  for f in "$d"/*; do
    [ -f "$f" ] && rfile "$f"
  done
}

# ---------------- 1. 环境 ----------------
sec "1. 环境"
p "date = $(date)"
p "id   = $(id)"
[ "$(id -u)" = "0" ] || p "警告: 非root运行, 大量节点会不可读! 请用: su -c sh 本脚本"
p "getenforce = $(getenforce 2>/dev/null)"
p "uname = $(uname -a)"

# ---------------- 2. 设备/系统属性 ----------------
sec "2. 设备与系统属性"
for k in ro.product.brand ro.product.manufacturer ro.product.marketname \
         ro.product.model ro.product.device ro.board.platform ro.hardware \
         ro.build.version.release ro.build.version.incremental \
         ro.build.version.security_patch ro.build.display.id \
         ro.build.version.oplusrom ro.oplus.version ro.vendor.oplus.version; do
  p "$k = $(getprop "$k" 2>/dev/null)"
done
p "--- getprop 过滤 oplus|oppo|coloros|panel|lcm|fps|refresh ---"
getprop 2>/dev/null | grep -iE 'oplus|oppo|coloros|panel|lcm|fps|refresh' >>"$OUT"

# ---------------- 3. 显示框架状态 ----------------
sec "3. dumpsys display (过滤 mode/refresh/fps/frame, 前120行)"
dumpsys display 2>/dev/null | grep -iE "mode|refresh|fps|frame" | head -120 >>"$OUT"
p "--- dumpsys SurfaceFlinger (过滤 refresh|fps|rate, 前50行) ---"
dumpsys SurfaceFlinger 2>/dev/null | grep -iE "refresh|fps|rate" | head -50 >>"$OUT"
p "cmd display get-user-preferred-display-mode = $(cmd display get-user-preferred-display-mode 2>/dev/null)"

# ---------------- 4. settings 刷新率相关 ----------------
sec "4. settings 刷新率相关"
p "system.peak_refresh_rate = $(settings get system peak_refresh_rate 2>/dev/null)"
p "system.min_refresh_rate  = $(settings get system min_refresh_rate 2>/dev/null)"
for ns in system secure global; do
  p "--- settings list $ns (过滤 refresh|rate|fps|mode, 前60行) ---"
  settings list "$ns" 2>/dev/null | grep -iE 'refresh|rate|fps|mode' | head -60 >>"$OUT"
done

# ---------------- 5. 内核显示节点 ----------------
rdir /sys/kernel/oplus_display
rdir /sys/kernel/oppo_display
rdir /proc/oplus_display
sec "5.x /sys/class/drm"
ls -la /sys/class/drm >>"$OUT" 2>&1
for d in /sys/class/drm/card*-*; do
  [ -d "$d" ] || continue
  p "--- $d ---"
  for f in status enabled modes modes_actual; do
    rfile "$d/$f"
  done
done

# ---------------- 6. 触控节点 ----------------
rdir /proc/touchpanel
rdir /sys/devices/virtual/touchpanel
for d in /sys/class/touchscreen/*; do
  [ -d "$d" ] && rdir "$d"
done
sec "6.x /proc/bus/input/devices (触控芯片身份)"
cat /proc/bus/input/devices >>"$OUT" 2>&1
sec "6.y 触控驱动 (i2c/spi)"
ls -la /sys/bus/i2c/drivers >>"$OUT" 2>&1
ls -la /sys/bus/spi/drivers >>"$OUT" 2>&1

# ---------------- 7. 调度与输入加速 ----------------
rdir /sys/module/cpu_boost/parameters
sec "7.x /proc/sys/kernel/sched*"
for f in /proc/sys/kernel/sched*; do
  rfile "$f"
done
sec "7.y cpufreq 摘要"
for d in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$d" ] || continue
  p "$d: governor=$(cat "$d/scaling_governor" 2>/dev/null) cur=$(cat "$d/scaling_cur_freq" 2>/dev/null) max=$(cat "$d/scaling_max_freq" 2>/dev/null)"
done

# ---------------- 8. 其他 oplus/boost 目录(仅列名) ----------------
sec "8. 相关目录扫描(仅列名)"
p "--- ls /sys/kernel ---"
ls /sys/kernel >>"$OUT" 2>&1
p "--- ls /proc 过滤 oplus|oppo|touch|fps ---"
ls /proc 2>/dev/null | grep -iE 'oplus|oppo|touch|fps' >>"$OUT"
p "--- ls /sys/module 过滤 oplus|boost|perf|touch|display|drm ---"
ls /sys/module 2>/dev/null | grep -iE 'oplus|boost|perf|touch|display|drm' >>"$OUT"
p "--- ls /sys/devices/platform 过滤 oplus|display|touch|drm|sde ---"
ls /sys/devices/platform 2>/dev/null | grep -iE 'oplus|display|touch|drm|sde' >>"$OUT"

sec "完成"
p "总行数: $(wc -l <"$OUT")"
echo "完成: $OUT ($(wc -l <"$OUT") 行)"
echo "本脚本只读, 未写入任何节点。把输出文件发回即可。"
