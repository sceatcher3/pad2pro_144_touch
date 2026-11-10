#!/system/bin/sh
# post-fs-data.sh — v1.3.2: 修复挂载
# 路线A: 若装有支持 extra_mount 的元模块(如 Magic Mount-rs, 配置
#        /data/adb/magic_mount/config.toml 里 extra_mount=["my_product"]),
#        模块内 my_product/ 会被原生挂载
# 路线B(本脚本兜底, v1.2 已验证有效): 手动 bind-mount 到两个视图
MODDIR=${0%/*}
DATA=/data/adb/p2p144
SRC=/my_product/etc/refresh_rate_config.xml
SRC2=/mnt/vendor/my_product/etc/refresh_rate_config.xml
DST=$MODDIR/my_product/etc/refresh_rate_config.xml

[ -f "$SRC" ] || exit 0
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
[ "$POLICY_OVERLAY" = "1" ] || exit 0
R=${POLICY_RATE:-4}
mkdir -p "$DATA" "$MODDIR/my_product/etc"

# 生成覆盖副本(sed 幂等: 即使读到被其他模块先行挂载过的内容也不会出错)
sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/" "$SRC" > "$DST" 2>>"$DATA/post_fs.log" || exit 0
chmod 644 "$DST" 2>/dev/null

# 防重复: mountinfo 里本模块文件已是该挂载点的源则跳过
mine_1(){ grep " /my_product/etc/refresh_rate_config.xml " /proc/self/mountinfo 2>/dev/null | grep -q "pad2pro_144_touch"; }
mine_2(){ grep " /mnt/vendor/my_product/etc/refresh_rate_config.xml " /proc/self/mountinfo 2>/dev/null | grep -q "pad2pro_144_touch"; }

if ! mine_1; then
  mount -o bind "$DST" "$SRC" 2>>"$DATA/post_fs.log"
  echo "$(date '+%m-%d %H:%M:%S') mount /my_product 视图 rc=$?" >>"$DATA/post_fs.log"
fi
if [ -f "$SRC2" ] && ! mine_2; then
  mount -o bind "$DST" "$SRC2" 2>>"$DATA/post_fs.log"
  echo "$(date '+%m-%d %H:%M:%S') mount /mnt/vendor 视图 rc=$?" >>"$DATA/post_fs.log"
fi

# 挂后验证: 实际读到的截断开关值
v=$(grep -o 'maxrefreshsettings="[0-9]*"' "$SRC" 2>/dev/null)
echo "$(date '+%m-%d %H:%M:%S') 挂后验证: $v" >>"$DATA/post_fs.log"
