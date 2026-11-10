#!/system/bin/sh
# post-fs-data.sh — v1.3.3: OverlayFS 路线
# 挂载交由 Hybrid Mount 以 overlay 模式合并模块内 my_product/;
# 本脚本只负责每次开机从当前原件刷新覆盖副本(OTA 自适应), 不做手动 mount
# (POLICY_OVERLAY=1 时才启用手动 bind-mount, 供无元模块的环境兜底)
MODDIR=${0%/*}
DATA=/data/adb/p2p144
SRC=/my_product/etc/refresh_rate_config.xml
SRC2=/mnt/vendor/my_product/etc/refresh_rate_config.xml
DST=$MODDIR/my_product/etc/refresh_rate_config.xml

[ -f "$SRC" ] || exit 0
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
R=${POLICY_RATE:-4}
mkdir -p "$DATA" "$MODDIR/my_product/etc"

# 刷新覆盖副本(sed 幂等: 读到被其他模块先行处理过的内容也不会出错)
sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/" "$SRC" > "$DST" 2>>"$DATA/post_fs.log" || exit 0
chmod 644 "$DST" 2>/dev/null
echo "$(date '+%m-%d %H:%M:%S') 覆盖副本已刷新(rate $R, OverlayFS 路线)" >>"$DATA/post_fs.log"

# ---- 可选手动 bind-mount(默认关; 无元模块环境兜底用) ----
if [ "$POLICY_OVERLAY" = "1" ]; then
  mine_1(){ grep " /my_product/etc/refresh_rate_config.xml " /proc/self/mountinfo 2>/dev/null | grep -q "pad2pro_144_touch"; }
  mine_2(){ grep " /mnt/vendor/my_product/etc/refresh_rate_config.xml " /proc/self/mountinfo 2>/dev/null | grep -q "pad2pro_144_touch"; }
  if ! mine_1; then
    mount -o bind "$DST" "$SRC" 2>>"$DATA/post_fs.log"
    echo "$(date '+%m-%d %H:%M:%S') mount /my_product rc=$?" >>"$DATA/post_fs.log"
  fi
  if [ -f "$SRC2" ] && ! mine_2; then
    mount -o bind "$DST" "$SRC2" 2>>"$DATA/post_fs.log"
    echo "$(date '+%m-%d %H:%M:%S') mount /mnt/vendor rc=$?" >>"$DATA/post_fs.log"
  fi
  v=$(grep -o 'maxrefreshsettings="[0-9]*"' "$SRC" 2>/dev/null)
  echo "$(date '+%m-%d %H:%M:%S') 挂后验证: $v" >>"$DATA/post_fs.log"
fi
