#!/system/bin/sh
# post-fs-data.sh — v1.5.1: 只生成/清理策略覆盖副本, 挂载完全交给元模块; 开机清空 post_fs.log
# v1.5.0: 删除全部自挂载(bind)逻辑
# 历史: v1.3.5 标准模块目录+bind兜底 → v1.4.1 修 sed /g → v1.4.2 bind判据看活文件
#       → v1.5.0 删除全部自挂载(bind)逻辑与 POLICY_MOUNT 键; 没装元模块/元模块不接管
#         my_product 时自动退化为纯运行时方案(SF强切+看门狗), 不再自己 bind。
# 副本每次开机从当前系统原件重生成(OTA 自适应、幂等); 先写临时文件再 cat 原地覆盖,
# 不换 inode(元模块已合并的挂载能立刻看到新内容), 也避免源已是本模块副本时截空。
MODDIR=${0%/*}
DATA=/data/adb/p2p144
SRC=/my_product/etc/refresh_rate_config.xml
DST=$MODDIR/my_product/etc/refresh_rate_config.xml
LOG=$DATA/post_fs.log

[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
R=${POLICY_RATE:-4}
mkdir -p "$DATA"

# v1.5.1: 每次开机清空日志, 只保留本次开机内容(WebUI 字节数/时间即本次活动量)
: >"$LOG" 2>/dev/null

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"; }
live_rate(){ grep -o 'maxrefreshsettings="[0-9]*"' "$1" 2>/dev/null | tail -n 1; }

# 无条件留一条启动记录: post_fs.log 里没有这一行 = 本脚本根本没跑(或写不了日志)
log "post-fs-data 启动 (目标 rate $R, 挂载交给元模块)"

# POLICY_ENABLE=0: 不生成覆盖副本, 并清掉上次生成的(退回纯运行时方案)
# 放在原件存在性检查之前, 保证关掉开关时一定清得掉残留副本
if [ "${POLICY_ENABLE:-1}" != "1" ]; then
  rm -rf "$MODDIR/my_product"
  log "POLICY_ENABLE=0, 已移除覆盖副本"
  exit 0
fi

[ -f "$SRC" ] || { log "未找到 $SRC, 跳过策略覆盖"; exit 0; }
mkdir -p "$MODDIR/my_product/etc"

# 刷新覆盖副本.
# maxrefreshsettings 的替换必须带 /g: 策略文件是单行 XML, 头部注释里也有同名字段,
# 不带 /g 只会改到第一个(注释), 真正的尾部 <config maxrefreshsettings="3"> 原样留下.
TMP=$DATA/.refresh_rate_config.new
if sed -E "s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/g" "$SRC" >"$TMP" 2>>"$LOG" && [ -s "$TMP" ]; then
  cat "$TMP" >"$DST" 2>>"$LOG"
  chmod 644 "$DST" 2>/dev/null
  got=$(live_rate "$DST")
  if [ "$got" = "maxrefreshsettings=\"$R\"" ]; then
    log "覆盖副本已生成(rate $R), 等待元模块合并"
  else
    log "错误: 覆盖副本尾部 [$got] != maxrefreshsettings=\"$R\", 策略文件格式可能已变"
  fi
else
  log "错误: 生成覆盖副本失败, 保留旧副本"
fi
rm -f "$TMP"

# 记录活文件状态供排查: 不是目标值 = 元模块没接管 my_product, 运行期由 SF+看门狗兜底
lv=$(live_rate "$SRC")
if [ "$lv" = "maxrefreshsettings=\"$R\"" ]; then
  log "活文件已是目标值($lv), 元模块已接管"
else
  log "活文件=${lv:-none}, 元模块未接管 my_product; 退化为纯运行时方案(SF+看门狗)"
fi