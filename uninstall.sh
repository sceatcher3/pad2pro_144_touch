#!/system/bin/sh
# uninstall.sh — 还原备份并清理
MODDIR=${0%/*}
DATA=/data/adb/p2p144
BK=$DATA/backup.conf

# 停看门狗
if [ -f "$DATA/daemon.pid" ]; then
  kill "$(cat "$DATA/daemon.pid" 2>/dev/null)" 2>/dev/null
fi

if [ -f "$BK" ]; then
  . "$BK"
  [ -n "$peak" ]        && settings put system peak_refresh_rate "$peak" 2>/dev/null
  [ -n "$min" ]         && settings put system min_refresh_rate "$min" 2>/dev/null
  [ -n "$oplus_rate" ]  && settings put secure oplus_customize_screen_refresh_rate "$oplus_rate" 2>/dev/null
  [ -n "$user_refresh" ] && settings put secure user_refresh_rate "$user_refresh" 2>/dev/null
  [ -n "$game_switch" ] && echo "$game_switch" > /proc/touchpanel/game_switch_enable 2>/dev/null
fi

# 清除用户首选显示模式(还原 -1)
cmd display clear-user-preferred-display-mode 2>/dev/null

# 摘除策略覆盖(两个视图都试)
umount /my_product/etc/refresh_rate_config.xml 2>/dev/null
umount /mnt/vendor/my_product/etc/refresh_rate_config.xml 2>/dev/null

rm -rf "$DATA"
