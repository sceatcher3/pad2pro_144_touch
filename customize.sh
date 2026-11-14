#!/system/bin/sh
# customize.sh — 安装器(KSU/Magisk 通用)
# v1.5.0: 安装输出只留结果行(删历史 changelog); 挂载完全交给元模块, 本脚本只生成策略覆盖副本
MODDIR=${MODPATH:-${MODDIR:-${0%/*}}}

model=$(getprop ro.product.model)
if [ "$model" != "OPD2413" ]; then
  ui_print "! 本模块为一加 Pad 2 Pro (OPD2413) 定制"
  abort "设备不匹配: $model"
fi
ui_print "- 设备: $model / ColorOS $(getprop ro.build.version.oplusrom 2>/dev/null)"

set_perm "$MODDIR/service.sh"       0 0 0755
set_perm "$MODDIR/apply.sh"         0 0 0755
set_perm "$MODDIR/action.sh"        0 0 0755
set_perm "$MODDIR/uninstall.sh"     0 0 0755
set_perm "$MODDIR/post-fs-data.sh"  0 0 0755

# ---- 生成策略覆盖副本, 交给元模块合并; 本模块不自挂载(v1.5.0) ----
OVSRC=/my_product/etc/refresh_rate_config.xml
if [ -f "$MODDIR/config.conf" ]; then
  . "$MODDIR/config.conf" 2>/dev/null
  if [ "${POLICY_ENABLE:-1}" != "1" ]; then
    rm -rf "$MODDIR/my_product"
    ui_print "- 策略覆盖已关闭(POLICY_ENABLE=0, 纯运行时方案)"
  elif [ -f "$OVSRC" ]; then
    R=${POLICY_RATE:-4}
    mkdir -p "$MODDIR/my_product/etc"
    DST=$MODDIR/my_product/etc/refresh_rate_config.xml
    TMP=$MODDIR/my_product/etc/.refresh_rate_config.new
    sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/g" "$OVSRC" > "$TMP"
    if [ -s "$TMP" ]; then
      cat "$TMP" > "$DST"   # 原地写, 不换 inode(旧副本可能正被元模块合并)
      rm -f "$TMP"
      set_perm "$DST" 0 0 0644
      ui_print "- 策略覆盖副本已生成(maxrefreshsettings->$R), 由元模块合并生效"
    else
      rm -f "$TMP"
      ui_print "! 策略覆盖副本生成失败(开机时 post-fs-data.sh 会再试)"
    fi
  fi
fi

mkdir -p /data/adb/p2p144 2>/dev/null

ui_print "- 重启后生效; 状态看模块卡 WebUI 或「操作」按钮"
ui_print "- 原始设置已自动备份, 卸载即还原"