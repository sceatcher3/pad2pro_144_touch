#!/system/bin/sh
# uninstall.sh — 还原备份并清理
# v1.6.0: 同时停触控守护(guard.pid)
# v1.5.0: 还原本模块真正改过的东西(settings 四键 + sensitive/smooth 档位);
#   旧版 backup.conf 里的 game_switch 行兼容还原(升级用户), 新备份不再含它。
MODDIR=${0%/*}
DATA=/data/adb/p2p144
BK=$DATA/backup.conf

# 停看门狗 + 触控守护(v1.6.0 两个独立进程)
for f in "$DATA/daemon.pid" "$DATA/guard.pid"; do
  [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null
done

if [ -f "$BK" ]; then
  . "$BK"
  [ -n "$peak" ]        && settings put system peak_refresh_rate "$peak" 2>/dev/null
  [ -n "$min" ]         && settings put system min_refresh_rate "$min" 2>/dev/null
  [ -n "$oplus_rate" ]  && settings put secure oplus_customize_screen_refresh_rate "$oplus_rate" 2>/dev/null
  [ -n "$user_refresh" ] && settings put secure user_refresh_rate "$user_refresh" 2>/dev/null
  # v1.5.0 新增: 触控持久档位还原(节点不存在时写入自然失败, 无害)
  [ -n "$sensitive" ]   && echo "$sensitive" > /proc/touchpanel/sensitive_level 2>/dev/null
  [ -n "$smooth" ]      && echo "$smooth" > /proc/touchpanel/smooth_level 2>/dev/null
  # 兼容旧版备份: 老版本常驻写过 game_switch, 升级用户卸载时写回安装时的值;
  # 新备份不含此行, 新装用户卸载不碰 game_switch(系统自管)
  [ -n "$game_switch" ] && echo "$game_switch" > /proc/touchpanel/game_switch_enable 2>/dev/null
fi

# 清除用户首选显示模式(还原 -1)
cmd display clear-user-preferred-display-mode 2>/dev/null

# 摘除历史版本(v1.4.x 及更早)自挂载残留; v1.5.0 起本模块不再 bind, 此处仅兜底清理
umount /my_product/etc/refresh_rate_config.xml 2>/dev/null
umount /mnt/vendor/my_product/etc/refresh_rate_config.xml 2>/dev/null

rm -rf "$DATA"