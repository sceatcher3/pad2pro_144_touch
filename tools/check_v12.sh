#!/system/bin/sh
# check_v12.sh — 一键体检: 结果存 /sdcard/Download/p2p_v12_check.txt (发回给 AI 排查用)
# v1.4.3: 不再硬编码 /data/adb/modules/pad2pro_144_touch, 按脚本自身位置定位模块目录;
#         输出从 /sdcard 根改到 /sdcard/Download/, 与 WebUI「导出日志」同一落点。
# 用法: sh <模块目录>/tools/check_v12.sh
D=${0%/*}
[ "$D" = "$0" ] && D=.
TOOLS=$(cd "$D" 2>/dev/null && pwd) || { echo "无法定位脚本目录: $0"; exit 1; }
MODULE=$(cd "$TOOLS/.." 2>/dev/null && pwd) || { echo "无法定位模块目录: $TOOLS"; exit 1; }
OUT=/sdcard/Download/p2p_v12_check.txt
mkdir -p /sdcard/Download 2>/dev/null

{
  echo "===== MODULE ====="
  echo "dir=$MODULE"
  echo "version=$(sed -n 's/^version=//p' "$MODULE/module.prop" 2>/dev/null | head -n 1)"
  echo "===== STATUS ====="
  sh "$MODULE/apply.sh" status
  echo "===== POST_FS ====="
  cat /data/adb/p2p144/post_fs.log 2>&1
  echo "===== P2P_LOG tail50 ====="
  tail -n 50 /data/adb/p2p144/p2p.log 2>&1
  echo "===== MOUNT ====="
  mount | grep refresh_rate
  echo "===== MOUNTINFO 归因 ====="
  grep refresh_rate /proc/self/mountinfo 2>&1
  echo "===== ETC 目录级挂载(元模块 overlay 常见) ====="
  grep -E 'on /(mnt/vendor/)?my_product/etc ' /proc/self/mountinfo 2>&1
  echo "===== MODULE OVERLAY 副本 ====="
  grep -o 'maxrefreshsettings="[0-9]*"' "$MODULE/my_product/etc/refresh_rate_config.xml" 2>&1
  echo "===== OVERLAY diff检查 ====="
  grep -o 'maxrefreshsettings="[0-9]*"' /my_product/etc/refresh_rate_config.xml
} >"$OUT" 2>&1

echo "已写入 $OUT"
ls -l "$OUT" 2>/dev/null