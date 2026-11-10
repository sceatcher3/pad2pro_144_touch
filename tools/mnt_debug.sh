#!/system/bin/sh
# 归因: 每条 refresh_rate 挂载的源路径(mountinfo root 字段)
OUT=/sdcard/p2p_mnt.txt
{
  echo "===== mountinfo(refresh_rate) ====="
  grep refresh_rate /proc/self/mountinfo
  echo "===== init(1号进程)的 mountinfo ====="
  grep refresh_rate /proc/1/mountinfo
} >"$OUT" 2>&1
echo "已写入 $OUT"
