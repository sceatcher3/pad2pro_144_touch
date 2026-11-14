#!/system/bin/sh
# customize.sh — 安装器(KSU/Magisk 通用)
# v1.4.1: 用安装器给的 MODPATH 定位模块目录(原来只用 $MODDIR, KSU/Magisk 不一定提供);
#   策略副本的 sed 补 /g(单行 XML 里头部注释也有 maxrefreshsettings, 漏改尾部总开关)
MODDIR=${MODPATH:-${MODDIR:-${0%/*}}}
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

# ---- v1.3.5: 生成策略覆盖副本, 交给任意元模块; 元模块没接管时开机自检 bind 兜底 ----
OVSRC=/my_product/etc/refresh_rate_config.xml
if [ -f "$MODDIR/config.conf" ]; then
  . "$MODDIR/config.conf" 2>/dev/null
  if [ "${POLICY_ENABLE:-1}" != "1" ]; then
    rm -rf "$MODDIR/my_product"
    ui_print "- 策略覆盖已关闭(POLICY_ENABLE=0, 纯看门狗方案)"
  elif [ -f "$OVSRC" ]; then
    R=${POLICY_RATE:-4}
    mkdir -p "$MODDIR/my_product/etc"
    DST=$MODDIR/my_product/etc/refresh_rate_config.xml
    TMP=$MODDIR/my_product/etc/.refresh_rate_config.new
    sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/g" "$OVSRC" > "$TMP"
    if [ -s "$TMP" ]; then
      cat "$TMP" > "$DST"   # 原地写, 不换 inode(旧副本可能正被 bind 挂着)
      rm -f "$TMP"
      set_perm "$DST" 0 0 0644
      ui_print "- 策略覆盖副本已生成(maxrefreshsettings->$R, 适配任意挂载元模块)"
    else
      rm -f "$TMP"
      ui_print "! 策略覆盖副本生成失败, 跳过(开机时 post-fs-data.sh 会再试)"
    fi
  fi
fi

mkdir -p /data/adb/p2p144 2>/dev/null

ui_print " "
ui_print "- 功能: 全局锁 144Hz(修复卡120) + 触控优化"
ui_print "- v1.3.5: 策略源头覆盖(自适配元模块, 重启生效)+三重锁+看门狗兜底"
ui_print "- v1.4.0: 只读 WebUI (KSU/APatch 模块卡片打开, 状态/日志/复制/保存)"
ui_print "- v1.4.1: 修策略覆盖 sed 漏 /g (自挂载了但活文件仍是 3)"
ui_print "- 原始设置已自动备份, 卸载即还原"
ui_print "- 配置: /data/adb/modules/pad2pro_144_touch/config.conf"
ui_print "- 重启后生效; 刷新率看 KSU 模块操作按钮或:"
ui_print "  sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
ui_print "=============================="
