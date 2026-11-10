#!/system/bin/sh
# 一键体检: 结果存 /sdcard/p2p_v12_check.txt (发回给 AI 排查用)
OUT=/sdcard/p2p_v12_check.txt
{
  echo "===== STATUS ====="
  sh /data/adb/modules/pad2pro_144_touch/apply.sh status
  echo "===== POST_FS ====="
  cat /data/adb/p2p144/post_fs.log 2>&1
  echo "===== P2P_LOG tail50 ====="
  tail -n 50 /data/adb/p2p144/p2p.log 2>&1
  echo "===== MOUNT ====="
  mount | grep refresh_rate
  echo "===== MOUNTINFO 归因 ====="
  grep refresh_rate /proc/self/mountinfo 2>&1
  echo "===== HM OVERLAY 挂载(目录级) ====="
  grep -E 'on /(mnt/vendor/)?my_product/etc ' /proc/self/mountinfo 2>&1
  echo "===== MODULE OVERLAY 副本 ====="
  grep -o 'maxrefreshsettings="[0-9]*"' /data/adb/modules/pad2pro_144_touch/my_product/etc/refresh_rate_config.xml 2>&1
  echo "===== OVERLAY diff检查 ====="
  grep -o 'maxrefreshsettings="[0-9]*"' /my_product/etc/refresh_rate_config.xml
} >"$OUT" 2>&1
echo "已写入 $OUT"
