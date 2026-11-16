#!/system/bin/sh
# diag_pin.sh — v1.6 只读诊断（不写任何 proc/settings/策略文件）
# 用途: 确认 120 掉帧的策略字段、活文件归属、触控回退现场
# 用法: su -c "sh /storage/emulated/0/Download/Code/Module/diag_pin.sh"
# 输出: /storage/emulated/0/Download/Code/Module/pad2pro-pin-diag-<时间>.txt
#       (目录不可写时自动回退 /sdcard/Download/Code/Module，再回退 /data/local/tmp)
# 说明: 30 秒轨迹期间请切换几个 app、锁屏再解锁、插拔一次充电器；脚本只读。
# 可选: PAD2PRO_DIAG_DIR=/some/dir  覆盖输出目录（调试用）
#       PAD2PRO_DIAG_FULL=1          输出策略/显示文件全文（默认只出摘要，避免 240KB 大文件）

MODDIR=${0%/*}
TOOLS=$(cd "$MODDIR" 2>/dev/null && pwd) || TOOLS="$MODDIR"
MODULE=$(cd "$TOOLS/.." 2>/dev/null && pwd) || MODULE="$TOOLS"
# 脚本可能被单独拷到 Download 跑; 此时退回标准模块路径
[ -d "$MODULE/my_product" ] || MODULE=/data/adb/modules/pad2pro_144_touch
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null)
OUTDIR=${PAD2PRO_DIAG_DIR:-/storage/emulated/0/Download/Code/Module}
mkdir -p "$OUTDIR" 2>/dev/null
OUT="$OUTDIR/pad2pro-pin-diag-$TS.txt"
if ! : >"$OUT" 2>/dev/null; then
  OUTDIR=/sdcard/Download/Code/Module
  mkdir -p "$OUTDIR" 2>/dev/null
  OUT="$OUTDIR/pad2pro-pin-diag-$TS.txt"
fi
if ! : >"$OUT" 2>/dev/null; then
  OUT="/data/local/tmp/pad2pro-pin-diag-$TS.txt"
fi
: >"$OUT" 2>/dev/null || { echo "无法创建输出文件"; exit 1; }
chmod 0644 "$OUT" 2>/dev/null

say() { echo "$*"; echo "$*" >>"$OUT"; }
sec() { echo "" >>"$OUT"; echo "================ $* ================" >>"$OUT"; }
p()   { echo "$*" >>"$OUT"; }
attr(){ grep -o "$1=\"[^\"]*\"" "$2" 2>/dev/null | tail -n 1 | cut -d'"' -f2; }
cnt() { grep -o "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
hashf(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else md5sum "$1" 2>/dev/null | cut -d' ' -f1; fi
}
FULL=${PAD2PRO_DIAG_FULL:-0}

say "diag_pin.sh 开始 $(date 2>/dev/null)"
say "输出: $OUT"
say "uid=$(id -u 2>/dev/null) model=$(getprop ro.product.model 2>/dev/null) build=$(getprop ro.build.display.id 2>/dev/null)"
say "uname=$(uname -a 2>/dev/null)"
say "uptime=$(uptime 2>/dev/null)"
say "提示: 接下来 30 秒请切换 app / 锁屏解锁 / 插拔充电器; 只读采集。"

sec "1. 策略文件摘要 (活文件与副本)"
for f in /my_product/etc/refresh_rate_config.xml \
         /data/adb/modules/extreme_gt/my_product/etc/refresh_rate_config.xml \
         "$MODULE/my_product/etc/refresh_rate_config.xml" \
         /data/system/refresh_rate_config.xml; do
  if [ -f "$f" ]; then
    p "--- $f ($(wc -c <"$f" 2>/dev/null) bytes) ---"
    p "config: $(grep -o '<config [^>]*>' "$f" 2>/dev/null | tail -n 1)"
    p "counts: item=$(cnt '<item ' "$f") win_false=$(cnt 'enableWinOverride="false"' "$f") default_max_rate=$(attr defaultMaxRate "$f") default_rate_id=$(attr defaultRateId "$f") rateid_4_1_2_4=$(cnt 'rateId="4-1-2-4"' "$f")"
    p "sha256: $(hashf "$f")"
    if [ "$FULL" = "1" ]; then
      p "--- 全文 ---"
      head -c 262144 "$f" >>"$OUT" 2>/dev/null
      echo "" >>"$OUT"
    else
      p "--- 前 15 行 (全文已省略; PAD2PRO_DIAG_FULL=1 输出) ---"
      head -n 15 "$f" >>"$OUT" 2>/dev/null
    fi
  else
    p "$f = (不存在)"
  fi
done

sec "2. 挂载归属 (只留来源文件)"
if grep -q 'refresh_rate_config.xml' /proc/self/mountinfo 2>/dev/null; then
  grep 'refresh_rate_config.xml' /proc/self/mountinfo | while read -r _ _ _ root mnt _; do
    p "src=$root mount=$mnt"
  done
else
  p "(无 bind 挂载, 活文件就是系统原件)"
fi

sec "3. 其他显示策略文件 (摘要)"
f=/my_product/etc/sys_dynamic_frame_config.xml
if [ -f "$f" ]; then
  p "--- $f ---"
  p "enable=$(attr enable "$f") thermalLimit=$(attr thermalLimit "$f")"
  p "targetFramerate: $(grep -o 'targetFramerate="[0-9]*"' "$f" 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
  p "sha256: $(hashf "$f")"
else
  p "$f = (不存在)"
fi
f=/my_product/etc/oplus_vrr_config.json
if [ -f "$f" ]; then
  p "--- $f ---"
  p "$(grep -E '"(version|sub_version|touch_idle|ignore_emitevent|hw_enable|sw_enable|adfr_enable|timeout|hw_lowest_rate)"' "$f" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
  p "sha256: $(hashf "$f")"
else
  p "$f = (不存在)"
fi
p "--- oplus_display 节点 ---"
for n in min_fps adfr_config dynamic_float_te power_status; do
  if [ -r "/sys/kernel/oplus_display/$n" ]; then
    p "/sys/kernel/oplus_display/$n = $(cat "/sys/kernel/oplus_display/$n" 2>/dev/null)"
  fi
done

sec "4. settings"
for k in system/peak_refresh_rate system/min_refresh_rate \
         secure/oplus_customize_screen_refresh_rate secure/user_refresh_rate \
         secure/oplus_refreshrate_override; do
  ns=${k%/*}; key=${k#*/}
  p "$ns/$key = $(settings get "$ns" "$key" 2>/dev/null)"
done

sec "5. display / SurfaceFlinger 快照"
p "--- dumpsys display (过滤) ---"
dumpsys display 2>/dev/null | grep -E 'mActiveModeId|mActiveRenderFrameRate|mDisplayModeSpecs|mRefreshRateChangeable|mUserPreferredModeId|mActiveSfDisplayMode|mDefaultModeId' | head -n 40 >>"$OUT"
p "--- SurfaceFlinger OPlusRefreshRateSelector ---"
dumpsys SurfaceFlinger 2>/dev/null | grep -A8 'OPlusRefreshRateSelector' | head -n 40 >>"$OUT"
p "--- SurfaceFlinger modes ---"
dumpsys SurfaceFlinger 2>/dev/null | grep -E 'vsyncRate=|mActiveSfDisplayMode' | head -n 20 >>"$OUT"

sec "6. 触控节点与场景通道"
for n in sensitive_level smooth_level game_switch_enable; do
  f="/proc/touchpanel/$n"
  if [ -f "$f" ]; then
    p "$f = $(cat "$f" 2>/dev/null | tr -d ' \n')"
  else
    p "$f = (不存在)"
  fi
done
if [ -f /proc/touchpanel/touch_scene_para ]; then
  p "--- touch_scene_para ---"
  cat /proc/touchpanel/touch_scene_para >>"$OUT" 2>/dev/null
fi
p "--- ls -l touch 节点 ---"
ls -l /proc/touchpanel/sensitive_level /proc/touchpanel/smooth_level /proc/touchpanel/touch_scene_para 2>/dev/null >>"$OUT"

sec "6b. p2p.log 尾部 200 行 (模块自己的记录)"
if [ -f /data/adb/p2p144/p2p.log ]; then
  tail -n 200 /data/adb/p2p144/p2p.log >>"$OUT" 2>/dev/null
else
  p "(不存在)"
fi

sec "7. 30 秒轨迹 (1Hz): 请切换 app / 锁屏解锁 / 插拔充电器"
p "时间 mode hz changeable sens smooth scene fg battery wake"
i=0
while [ "$i" -lt 30 ]; do
  i=$((i + 1))
  d=$(dumpsys display 2>/dev/null)
  mid=$(echo "$d" | grep -o 'mActiveModeId=[0-9]*' | head -n 1 | cut -d= -f2)
  hz=$(echo "$d" | grep -o 'mActiveRenderFrameRate=[0-9]*' | head -n 1 | cut -d= -f2)
  ch=$(echo "$d" | grep -o 'mRefreshRateChangeable: [a-z]*' | head -n 1 | awk '{print $2}')
  sl=$(cat /proc/touchpanel/sensitive_level 2>/dev/null | tr -d ' \n')
  sm=$(cat /proc/touchpanel/smooth_level 2>/dev/null | tr -d ' \n')
  sc=$(cat /proc/touchpanel/touch_scene_para 2>/dev/null | tr '\n' ';')
  fg=$(dumpsys activity activities 2>/dev/null | grep -m1 'mResumedActivity' | sed 's/.*mResumedActivity: //' | cut -c1-80)
  bat=$(dumpsys battery 2>/dev/null | grep -E 'AC powered|USB powered' | tr '\n' ' ')
  wake=$(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -n 1)
  p "$(date +%H:%M:%S) mode=${mid:-?} hz=${hz:-?} ch=${ch:-?} sens=${sl:-?} smooth=${sm:-?} scene=[$sc] fg=[$fg] $bat $wake"
  sleep 1
done

sec "8. 汇总"
p "sens=4 行数: $(grep -c 'sens=4' "$OUT" 2>/dev/null)"
p "sens=0 行数: $(grep -c 'sens=0' "$OUT" 2>/dev/null)"
p "mode=1 行数: $(grep -c 'mode=1 ' "$OUT" 2>/dev/null)"
p "mode=7 行数: $(grep -c 'mode=7 ' "$OUT" 2>/dev/null)"
p "完成 $(date 2>/dev/null)"

chmod 0644 "$OUT" 2>/dev/null
say "完成: $OUT"
say "请把该文件发回。脚本只读，未修改任何节点/设置/策略文件。"