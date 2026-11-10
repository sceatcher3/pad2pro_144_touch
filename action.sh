#!/system/bin/sh
# action.sh — KSU 管理器"操作"按钮: 立即应用并显示状态
MODDIR=${0%/*}
type ui_print >/dev/null 2>&1 || ui_print(){ echo "$@"; }

out=$(sh "$MODDIR/apply.sh" once 2>&1)
ui_print "$out"
ui_print "----------------------------"
st=$(sh "$MODDIR/apply.sh" status 2>&1)
ui_print "$st"
