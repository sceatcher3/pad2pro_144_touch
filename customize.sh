#!/system/bin/sh
# customize.sh — 安装器(KSU/Magisk 通用)
ui_print "=============================="
ui_print " Pad 2 Pro 144Hz Fix & TouchTune"
ui_print "=============================="

model=$(getprop ro.product.model)
rom=$(getprop ro.build.version.oplusrom 2>/dev/null)
ui_print "设备: $model"
ui_print "系统: ColorOS $rom / Android $(getprop ro.build.version.release)"

if [ "$model" != "OPD2413" ]; then
  ui_print "! 本模块为一加 Pad 2 Pro (OPD2413) 定制"
  ui_print "! 当前设备不匹配, 终止安装"
  abort "设备不匹配: $model"
fi

set_perm "$MODDIR/service.sh"       0 0 0755
set_perm "$MODDIR/apply.sh"         0 0 0755
set_perm "$MODDIR/action.sh"        0 0 0755
set_perm "$MODDIR/uninstall.sh"     0 0 0755
set_perm "$MODDIR/post-fs-data.sh"  0 0 0755

# ---- v1.3: 生成策略覆盖文件, 由 KSU 原生挂载(元模块机制, 不再手动 mount) ----
OVSRC=/my_product/etc/refresh_rate_config.xml
if [ -f "$OVSRC" ] && [ -f "$MODDIR/config.conf" ]; then
  . "$MODDIR/config.conf" 2>/dev/null
  if [ "$POLICY_OVERLAY" = "1" ]; then
    R=${POLICY_RATE:-4}
    mkdir -p "$MODDIR/my_product/etc"
    sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/" "$OVSRC" > "$MODDIR/my_product/etc/refresh_rate_config.xml"
    set_perm "$MODDIR/my_product/etc/refresh_rate_config.xml" 0 0 0644
    ui_print "- 策略覆盖已生成(maxrefreshsettings->$R, KSU挂载)"
  else
    rm -rf "$MODDIR/my_product"
  fi
fi

mkdir -p /data/adb/p2p144 2>/dev/null

ui_print " "
ui_print "- 功能: 全局锁 144Hz(修复卡120) + 触控优化"
ui_print "- v1.2: 策略源头覆盖(Plan B, 重启生效)+看门狗兜底"
ui_print "- 原始设置已自动备份, 卸载即还原"
ui_print "- 配置: /data/adb/modules/pad2pro_144_touch/config.conf"
ui_print "- 重启后生效; 刷新率看 KSU 模块操作按钮或:"
ui_print "  sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
ui_print "=============================="
