#!/system/bin/sh
# post-fs-data.sh — v1.6.0: 策略副本补齐 defaultRateId/defaultMaxRate/enableWinOverride,
#   先写临时文件并校验, 通过后才覆盖副本(校验失败保留旧副本).
# v1.5.1: 只生成/清理策略覆盖副本, 挂载完全交给元模块; 开机清空 post_fs.log
# v1.5.0: 删除全部自挂载(bind)逻辑
# 副本每次开机从当前系统原件重生成(OTA 自适应、幂等); 先写临时文件再 cat 原地覆盖,
# 不换 inode(元模块已合并的挂载能立刻看到新内容), 也避免源已是本模块副本时截空。
# v1.6 真机发现: 活文件里可能根本没有 defaultRateId(defaultMaxRate/enableWinOverride 也缺),
#   所以三类字段都要处理; defaultRateId 只在存在时改写(大小写 R, 与小写 rateId 分开匹配).
MODDIR=${0%/*}
DATA=/data/adb/p2p144
SRC=/my_product/etc/refresh_rate_config.xml
DST=$MODDIR/my_product/etc/refresh_rate_config.xml
LOG=$DATA/post_fs.log

[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
R=${POLICY_RATE:-4}
DM=${POLICY_DEFAULT_MAX_RATE:-144}
WIN=${POLICY_WIN_OVERRIDE:-all}
mkdir -p "$DATA"

# v1.5.1: 每次开机清空日志, 只保留本次开机内容(WebUI 字节数/时间即本次活动量)
: >"$LOG" 2>/dev/null

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"; }
attr(){ grep -o "$1=\"[^\"]*\"" "$2" 2>/dev/null | tail -n 1 | cut -d'"' -f2; }
cnt(){ grep -o "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }

# 校验副本: maxrefreshsettings=目标档; defaultMaxRate=目标Hz(空=不写); defaultRateId(若存在)首尾=目标档;
# WIN=all 时每个 <item> 都带 enableWinOverride="false". 返回非空字符串 = 失败原因
validate_copy(){
  f=$1; bad=""
  [ "$(attr maxrefreshsettings "$f")" = "$R" ] || bad="$bad rateId"
  if [ -n "$DM" ] && [ "$(attr defaultMaxRate "$f")" != "$DM" ]; then bad="$bad defaultMaxRate"; fi
  dri=$(attr defaultRateId "$f")
  if [ -n "$dri" ] && ! echo "$dri" | grep -qE "^$R-[0-9]+-[0-9]+-$R$"; then bad="$bad defaultRateId=$dri"; fi
  if [ "$WIN" = "all" ]; then
    items=$(cnt '<item ' "$f")
    wf=$(cnt 'enableWinOverride="false"' "$f")
    if [ "$items" -eq 0 ] || [ "$wf" != "$items" ]; then bad="$bad winOverride=$wf/$items"; fi
  fi
  echo "$bad"
}

# 无条件留一条启动记录: post_fs.log 里没有这一行 = 本脚本根本没跑(或写不了日志)
log "post-fs-data 启动 (目标 rate $R, defaultMaxRate=${DM:-none}, winOverride=$WIN, 挂载交给元模块)"

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
# maxrefreshsettings 的替换必须带 /g: 头部注释里也有同名字段, 不带 /g 只会改到第一个(注释).
# defaultRateId 单独一条(大写 R, 不能被 s/rateId=/ 顺带匹配); defaultMaxRate 先删后加(幂等);
# enableWinOverride 先删后加, 避免重复属性.
EXPR="s/defaultRateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/defaultRateId=\"$R-\2-\3-$R\"/g"
EXPR="$EXPR; s/rateId=\"([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\"/rateId=\"$R-\2-\3-$R\"/g"
EXPR="$EXPR; s/maxrefreshsettings=\"[0-9]+\"/maxrefreshsettings=\"$R\"/g"
[ -n "$DM" ] && EXPR="$EXPR; s/ defaultMaxRate=\"[0-9.]*\"//g; s/<config /<config defaultMaxRate=\"$DM\" /"
[ "$WIN" = "all" ] && EXPR="$EXPR; s/ enableWinOverride=\"[a-z]*\"//g; s|<item ([^>]*[^ /]) */>|<item \1 enableWinOverride=\"false\" />|g"

TMP=$DATA/.refresh_rate_config.new
if sed -E "$EXPR" "$SRC" >"$TMP" 2>>"$LOG" && [ -s "$TMP" ]; then
  bad=$(validate_copy "$TMP")
  if [ -z "$bad" ]; then
    cat "$TMP" >"$DST" 2>>"$LOG"
    chmod 644 "$DST" 2>/dev/null
    log "覆盖副本已生成并通过校验 (rate $R, defaultMaxRate=${DM:-none}, winOverride=$WIN, $(cnt '<item ' "$DST") items), 等待元模块合并"
  else
    log "错误: 覆盖副本校验失败 [$bad], 保留旧副本"
  fi
else
  log "错误: 生成覆盖副本失败, 保留旧副本"
fi
rm -f "$TMP"

# 记录活文件状态供排查: 不是目标值 = 元模块没接管 my_product, 运行期由 SF+看门狗兜底
lv=$(attr maxrefreshsettings "$SRC")
ldm=$(attr defaultMaxRate "$SRC")
lwf=$(cnt 'enableWinOverride="false"' "$SRC")
lit=$(cnt '<item ' "$SRC")
if [ "$lv" = "$R" ]; then
  log "活文件已达标(rate=$lv defaultMaxRate=${ldm:-none} winOverride=$lwf/$lit), 外部已接管"
else
  log "活文件=${lv:-none} (defaultMaxRate=${ldm:-none} winOverride=$lwf/$lit), 外部未接管 my_product; 退化为纯运行时方案"
fi