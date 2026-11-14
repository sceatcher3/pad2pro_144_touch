#!/system/bin/sh
# post-fs-data.sh — v1.3.5 逻辑: 标准模块目录 + 自检兜底
# v1.4.1 修复: 策略文件是单行 XML, 头部注释里也有一个 maxrefreshsettings="3";
#   旧 sed 漏了 /g, 只改到注释那一个, 尾部总开关仍是 3 -> bind 成功但覆盖"未生效"
# v1.4.2: bind 判据改成"活文件内容对不对"(不再只看 mountinfo), 启动必留一行日志;
#   service.sh 会在 late_start 再跑本脚本一次, 兜住"元模块后叠加把 bind 盖住"的情况
# v1.4.3: 无逻辑改动(策略覆盖/挂载判据不变), 仅为版本号同步
# 覆盖副本生成到 <模块>/my_product/etc/, 任何元模块(overlay/magic/VFS)都能按分区目录识别;
# 若元模块没接管 my_product, POLICY_MOUNT=auto 时自己 bind 兜底, 不依赖任何元模块的 CLI/配置
MODDIR=${0%/*}
MODNAME=${MODDIR##*/}
DATA=/data/adb/p2p144
SRC=/my_product/etc/refresh_rate_config.xml
SRC2=/mnt/vendor/my_product/etc/refresh_rate_config.xml
DST=$MODDIR/my_product/etc/refresh_rate_config.xml
LOG=$DATA/post_fs.log

[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
R=${POLICY_RATE:-4}
MODE=${POLICY_MOUNT:-auto}
mkdir -p "$DATA"

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"; }
live_rate(){ grep -o 'maxrefreshsettings="[0-9]*"' "$1" 2>/dev/null | tail -n 1; }

# v1.4.2: 无条件留一条启动记录。post_fs.log 里没有这一行 = 本脚本根本没跑(或写不了日志),
# 排查"策略没生效"时先看这一条, 别再猜是副本错了还是挂载错了
log "post-fs-data 启动 (目标 rate $R, mount=$MODE)"

# POLICY_ENABLE=0: 不生成覆盖副本, 并清掉上次生成的(退回纯看门狗方案)
# 放在原件存在性检查之前, 保证关掉开关时一定清得掉残留副本
if [ "${POLICY_ENABLE:-1}" != "1" ]; then
  rm -rf "$MODDIR/my_product"
  log "POLICY_ENABLE=0, 已移除覆盖副本"
  exit 0
fi

[ -f "$SRC" ] || { log "未找到 $SRC, 跳过策略覆盖"; exit 0; }
mkdir -p "$MODDIR/my_product/etc"

# 刷新覆盖副本.
# v1.4.1: 两处修正
#   1) maxrefreshsettings 的替换必须带 /g: 策略文件是单行 XML, 头部注释里也有同名字段,
#      不带 /g 只会改到第一个(注释), 真正的尾部 <config maxrefreshsettings="3"> 原样留下.
#   2) 先写临时文件再原地 cat 回副本: 不改 inode, 元模块已合并的挂载能立刻看到新内容;
#      也避免 SRC 已经是本模块副本(同一 inode)时 "sed 读 DST > DST" 把文件截成空.
TMP=$DATA/.refresh_rate_config.new
if sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/g" "$SRC" >"$TMP" 2>>"$LOG" && [ -s "$TMP" ]; then
  cat "$TMP" >"$DST" 2>>"$LOG"
  chmod 644 "$DST" 2>/dev/null
  got=$(live_rate "$DST")
  if [ "$got" = "maxrefreshsettings=\"$R\"" ]; then
    log "覆盖副本已生成(rate $R)"
  else
    log "错误: 覆盖副本尾部 [$got] != maxrefreshsettings=\"$R\", 策略文件格式可能已变"
  fi
else
  log "错误: 生成覆盖副本失败, 保留旧副本"
fi
rm -f "$TMP"

# ---- 兜底挂载: 只在元模块没接管时补, 不假设元模块类型 ----
# v1.4.2: 判据从"mountinfo 里有没有本模块的 bind"改成"活文件内容对不对"。
#   元模块可能在 post-fs-data 之后才叠加 /my_product, 把早先的 bind 盖住;
#   那时 mountinfo 里仍留着我们的 bind, 旧写法会误判"已挂"而跳过, 活文件就一直停在 3。
bind_one(){
  t=$1; force=$2
  [ -f "$t" ] || { log "跳过(不存在): $t"; return 0; }
  if [ "$force" != "1" ] && [ "$(live_rate "$t")" = "maxrefreshsettings=\"$R\"" ]; then
    log "已是目标值, 跳过 bind: $t"
    return 0
  fi
  if [ "$force" = "1" ] && grep " $t " /proc/self/mountinfo 2>/dev/null | grep -q "$MODNAME"; then
    log "已存在本模块 bind: $t"
    return 0
  fi
  before=$(live_rate "$t")
  mount -o bind "$DST" "$t" 2>>"$LOG"
  rc=$?
  log "bind $t rc=$rc (bind 前 ${before:-空})"
  return 0
}

bind_all(){
  bind_one "$SRC" "$1"
  [ -f "$SRC2" ] && bind_one "$SRC2" "$1"
  log "挂后验证: $(live_rate "$SRC")"
}

case "$MODE" in
  never)
    log "POLICY_MOUNT=never, 挂载完全交给元模块"
    ;;
  always)
    bind_all 1
    ;;
  *)
    if [ "$(live_rate "$SRC")" = "maxrefreshsettings=\"$R\"" ]; then
      log "策略已生效($(live_rate "$SRC")), 元模块已接管, 跳过 bind"
    else
      log "策略未生效($(live_rate "$SRC")), 启用 bind 兜底"
      bind_all 0
    fi
    ;;
esac