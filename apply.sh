#!/system/bin/sh
# apply.sh — Pad 2 Pro 144Hz 修复 + 触控优化 核心
# v1.6.2: 触控档位默认 4/1 -> 2/3(FPS 准星微抖); game_switch=1 作为高轮询率唯一入口保留;
#   守护写回前用触摸 IRQ 计数差值避让报点活动(fd_touch_count 受 face_detect_support
#   门控本机不存在), 连续避让 TOUCH_GUARD_DEFER_MAX tick 后强制写一次;
#   status/应用快照共用一次 dumpsys display; trim_log 临时文件带 PID 防并发互踩
# v1.6.1: 新增 TOUCH_GAME_SWITCH(默认 1): 写 game_switch_enable=1(固件 GAME_ON),
#   开机写一次 + 触控守护维护; -1=不碰. 本机 DTS 无 smooth/sensitive 联动, 只发固件命令.
# v1.6.0: 策略副本配套 defaultMaxRate/enableWinOverride 校验(policy_complete);
#   新增触控守护 apply.sh guard(1s 巡检, 回退即写回, 每分钟写回上限, log/off 可切);
#   status 追加 policy_live_src/default_rate_id/default_max_rate/win_override/
#   policy_complete/touch_target_*/touch_guard/touch_daemon/touch_fallback
# v1.5.2: REFRESH_MIN 默认 120 (min=peak=144 会让 ColorOS 固定刷新率, 实测不再 modeset);
#   settings 写入加 content/runcon 回退 + 回读校验; SF 1035 默认关闭(本机实测空操作);
#   看门狗改验 mActiveModeId/mRefreshRateChangeable; status 追加 refresh_changeable/sf_1035
# v1.5.1: boot/daemon 开机清空 p2p.log(once 不清); discover() 对 boost 目录改枚举;
#   status 措辞结果导向(policy_source 键值不变)
# v1.5.0: 曾以 SF 1035 为唯一运行期强制手段(本机后续实测为空操作, v1.5.2 已默认关闭);
#   settings 仅 boot/once 写一次做 UI 一致性;
#   看门狗单职责盯实测帧率(稳态10s/复查2s/失败退避60s封顶/日志限频);
#   触控改持久档位(sensitive_level/smooth_level), 不再常驻写 game_switch;
#   sf_mode_id 守护进程内缓存, 失败才重解析; status 追加 policy_source/touch_sensitive/touch_smooth
# 用法: sh apply.sh boot|daemon|guard|once|status
# boot/daemon: 应用一次并进入看门狗循环  once: 应用一次  status: 打印当前状态

MODDIR=${0%/*}
DATA=/data/adb/p2p144
LOGF=$DATA/p2p.log
BK=$DATA/backup.conf
PIDF=$DATA/daemon.pid
GUARDF=$DATA/guard.pid
TOUCHF=$DATA/touch_fallback
POLICY_SRC=/my_product/etc/refresh_rate_config.xml

# ---- 读取配置 ----
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
REFRESH_PEAK=${REFRESH_PEAK:-144.0}
REFRESH_MIN=${REFRESH_MIN:-120.0}
USER_REFRESH_RATE=${USER_REFRESH_RATE:-144}
OPLUS_REFRESH_KEY=${OPLUS_REFRESH_KEY:-4}
SF_FALLBACK_ID=${SF_FALLBACK_ID:-6}
SF_1035_ENABLE=${SF_1035_ENABLE:-0}
TOUCH_SENSITIVE_LEVEL=${TOUCH_SENSITIVE_LEVEL:-2}
TOUCH_SMOOTH_LEVEL=${TOUCH_SMOOTH_LEVEL:-3}
TOUCH_GAME_SWITCH=${TOUCH_GAME_SWITCH:-1}
TOUCH_IRQ_AFFINITY=${TOUCH_IRQ_AFFINITY:-auto}
TOUCH_GUARD=${TOUCH_GUARD:-pin}
TOUCH_GUARD_INTERVAL=${TOUCH_GUARD_INTERVAL:-1}
TOUCH_GUARD_MAX_WRITES=${TOUCH_GUARD_MAX_WRITES:-6}
TOUCH_GUARD_DEFER_MAX=${TOUCH_GUARD_DEFER_MAX:-10}
POLICY_DEFAULT_MAX_RATE=${POLICY_DEFAULT_MAX_RATE:-144}
POLICY_WIN_OVERRIDE=${POLICY_WIN_OVERRIDE:-all}
WATCH_INTERVAL=${WATCH_INTERVAL:-10}
TARGET_HZ=${TARGET_HZ:-144}

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOGF"; }
trim_log(){
  [ -f "$LOGF" ] || return 0
  sz=$(wc -c <"$LOGF")
  # tmp 名带 PID: guard 启动与 once 可能并发截断, 共用 .t 会互相覆盖;
  # tail 失败不 mv(保留原日志), 残留 tmp 清掉
  [ "$sz" -gt 102400 ] && { tail -n 300 "$LOGF" >"$LOGF.t.$$" && mv "$LOGF.t.$$" "$LOGF" || rm -f "$LOGF.t.$$"; }
  return 0
}
screen_on(){ dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'; }
# ---- settings 读写(v1.5.2) ----
# 本机实测: ksu 域直接 settings put/get 会 Failed transaction; su 2000 仍是 ksu 域;
# content update 返回0但0行. 所以依次尝试 settings -> runcon shell 域 -> content,
# 并用 content 回读校验; 失败返回1, 由调用方决定是否记日志.
setting_get(){
  ns=$1; key=$2
  v=$(settings get "$ns" "$key" 2>/dev/null)
  [ -n "$v" ] && [ "$v" != "null" ] && { echo "$v"; return 0; }
  command -v content >/dev/null 2>&1 || return 1
  v=$(content query --uri "content://settings/$ns" --projection value --where "name='$key'" 2>/dev/null | sed -n 's/.*value=//p' | head -n 1)
  [ -n "$v" ] && { echo "$v"; return 0; }
  return 1
}
setting_put(){
  ns=$1; key=$2; val=$3
  if settings put "$ns" "$key" "$val" 2>/dev/null; then
    got=$(setting_get "$ns" "$key")
    [ "$got" = "$val" ] && return 0
  fi
  if command -v runcon >/dev/null 2>&1; then
    runcon u:r:shell:s0 /system/bin/settings put "$ns" "$key" "$val" 2>/dev/null
    got=$(setting_get "$ns" "$key")
    [ "$got" = "$val" ] && return 0
  fi
  if command -v content >/dev/null 2>&1; then
    content update --uri "content://settings/$ns" --bind "value:s:$val" --where "name='$key'" >/dev/null 2>&1
  fi
  got=$(setting_get "$ns" "$key")
  [ "$got" = "$val" ]
}
cur_peak(){ setting_get system peak_refresh_rate; }
cur_min(){ setting_get system min_refresh_rate; }
# v1.6.2: 可选参数=预取的 dumpsys display 输出(status/应用快照内多次查询共用一次 dump,
# 省 2-5 次 binder 调用); 不传参仍现取(看门狗每次巡检语义不变)。printf 避免 echo 转义差异。
render_hz(){ printf '%s\n' "${1:-$(dumpsys display 2>/dev/null)}" | grep -o 'mActiveRenderFrameRate=[0-9]*' | head -n 1 | cut -d= -f2; }
mode_id(){ printf '%s\n' "${1:-$(dumpsys display 2>/dev/null)}" | grep -o 'mActiveModeId=[0-9]*' | head -n 1 | cut -d= -f2; }
refresh_changeable(){ printf '%s\n' "${1:-$(dumpsys display 2>/dev/null)}" | grep -o 'mRefreshRateChangeable: [a-z]*' | head -n 1 | awk '{print $2}'; }
gs_state(){ sed 's/,.*//' /proc/touchpanel/game_switch_enable 2>/dev/null | tr -d ' '; }
tp_level(){ cat "/proc/touchpanel/$1" 2>/dev/null | tr -d ' \n'; }
# 策略文件里的截断开关(取最后一个是真正的总开关; 头部注释里那个是过时的)
policy_rate(){ grep -o 'maxrefreshsettings="[0-9]*"' "$1" 2>/dev/null | tail -n 1; }
# v1.6.0: 策略字段读取/校验(值与 post-fs-data.sh 的 validate_copy 口径一致)
policy_attr(){ grep -o "$1=\"[^\"]*\"" "$2" 2>/dev/null | tail -n 1 | cut -d'"' -f2; }
policy_count(){ grep -o "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
policy_src(){
  line=$(grep 'refresh_rate_config.xml' /proc/self/mountinfo 2>/dev/null | head -n 1)
  [ -n "$line" ] || { echo system; return 0; }
  root=$(echo "$line" | awk '{print $4}')
  case "$root" in
    */modules/*/my_product/*) echo "$root" | sed 's|.*/modules/\([^/]*\)/.*|\1|' ;;
    *) echo "${root:-unknown}" ;;
  esac
}
# 活文件是否完整: rateId 目标档 + defaultMaxRate 目标Hz + (若存在)defaultRateId 首尾目标档 + 全部 item 关 winOverride
policy_complete(){
  [ -f "$POLICY_SRC" ] || { echo 0; return 0; }
  ok=1
  [ "$(policy_attr maxrefreshsettings "$POLICY_SRC")" = "${POLICY_RATE:-4}" ] || ok=0
  if [ -n "${POLICY_DEFAULT_MAX_RATE:-144}" ]; then
    [ "$(policy_attr defaultMaxRate "$POLICY_SRC")" = "$POLICY_DEFAULT_MAX_RATE" ] || ok=0
  fi
  dri=$(policy_attr defaultRateId "$POLICY_SRC")
  if [ -n "$dri" ]; then
    echo "$dri" | grep -qE "^${POLICY_RATE:-4}-[0-9]+-[0-9]+-${POLICY_RATE:-4}$" || ok=0
  fi
  if [ "${POLICY_WIN_OVERRIDE:-all}" = "all" ]; then
    items=$(policy_count '<item ' "$POLICY_SRC"); wf=$(policy_count 'enableWinOverride="false"' "$POLICY_SRC")
    if [ "$items" -eq 0 ] || [ "$wf" != "$items" ]; then ok=0; fi
  fi
  echo "$ok"
}

# ---- 备份原始值(仅首次) ----
# v1.6.1: 重新备份 game_switch(本模块在 TOUCH_GAME_SWITCH != -1 时会写它)
# 旧版 backup.conf 没有这一行: 卸载时不会碰 game_switch(升级用户兼容)
save_backup(){
  [ -f "$BK" ] && return 0
  mkdir -p "$DATA"
  {
    echo "peak=$(cur_peak)"
    echo "min=$(cur_min)"
    echo "oplus_rate=$(setting_get secure oplus_customize_screen_refresh_rate)"
    echo "user_refresh=$(setting_get secure user_refresh_rate)"
    echo "sensitive=$(tp_level sensitive_level)"
    echo "smooth=$(tp_level smooth_level)"
    echo "game_switch=$(gs_state)"
  } >"$BK"
  log "已备份原始设置 -> $BK"
}

# ---- settings 写入: boot/once 各一次 + 漂移时用于触发系统重新 modeset ----
# v1.5.2: 写入走 setting_put(settings -> runcon shell 域 -> content, 回读校验);
# min=120/peak=144 保持 max-min>1, 让 ColorOS 的 mRefreshRateChangeable=true。
apply_refresh(){
  quiet=${1:-}
  setting_put system peak_refresh_rate "$REFRESH_PEAK" || [ "$quiet" = quiet ] || log "peak_refresh_rate 写入失败(settings/runcon/content 均被拒)"
  setting_put system min_refresh_rate "$REFRESH_MIN" || [ "$quiet" = quiet ] || log "min_refresh_rate 写入失败(settings/runcon/content 均被拒)"
  setting_put secure oplus_customize_screen_refresh_rate "$OPLUS_REFRESH_KEY" || [ "$quiet" = quiet ] || log "oplus_customize_screen_refresh_rate 写入失败"
  setting_put secure user_refresh_rate "$USER_REFRESH_RATE" || [ "$quiet" = quiet ] || log "user_refresh_rate 写入失败"
  # 竖屏参数优先(面板原生 2400x3392), 失败换横屏试
  cmd display set-user-preferred-display-mode 2400 3392 "$REFRESH_PEAK" 2>/dev/null
  um=$(cmd display get-user-preferred-display-mode 2>/dev/null)
  case "$um" in
    *null*|"") cmd display set-user-preferred-display-mode 3392 2400 "$REFRESH_PEAK" 2>/dev/null ;;
  esac
}

# ---- SF 1035 后备(默认关闭) ----
# v1.5.2 实测: 本机 1035 为空操作(返回 Parcel(NULL), backdoor pid 始终 0, -1 为 Invalid argument),
# 默认 SF_1035_ENABLE=0; 仅在其他 ROM/旧版本确认有效时开启。开启时仍缓存解析结果。
SF_ID=""
sf_mode_id(){
  if [ -n "$SF_ID" ]; then echo "$SF_ID"; return 0; fi
  id=$(dumpsys SurfaceFlinger 2>/dev/null | grep -o "id=[0-9]*, hwcId=[0-9]*, resolution=[0-9]*x[0-9]*, vsyncRate=${TARGET_HZ}.00" | head -n 1 | sed 's/id=\([0-9]*\),.*/\1/')
  [ -n "$id" ] || id=$SF_FALLBACK_ID
  SF_ID=$id
  echo "$id"
}
sf_apply(){
  sid=$(sf_mode_id)
  service call SurfaceFlinger 1035 i32 "$sid" >/dev/null 2>&1
  log "SF 1035 强切 mode $sid (实验开关)"
}

verify_and_fix(){
  ds=$(dumpsys display 2>/dev/null)
  hz=$(render_hz "$ds"); mid=$(mode_id "$ds"); ch=$(refresh_changeable "$ds")
  if [ "$hz" != "$TARGET_HZ" ]; then
    log "实测 ${hz:-?}Hz != ${TARGET_HZ}Hz (mode=${mid:-?} changeable=${ch:-?})"
    if [ "$ch" = "false" ]; then
      log "固定刷新率模式: 设置→显示与亮度→屏幕刷新率 选「智能切换」; 或把 REFRESH_MIN 改为 120/10"
    fi
    [ "$SF_1035_ENABLE" = "1" ] && sf_apply
  fi
}

# ---- 触控 IRQ 绑最强 CPU 簇 ----
touch_irq_affinity(){
  [ "$TOUCH_IRQ_AFFINITY" = "0" ] && return 0
  irq=$(grep -iE 'touch' /proc/interrupts 2>/dev/null | grep -oE '^[ ]*[0-9]+' | head -n 1 | tr -d ' ')
  if [ -z "$irq" ]; then log "未找到触控 IRQ, 跳过亲和性"; return 0; fi
  if [ "$TOUCH_IRQ_AFFINITY" = "auto" ]; then
    best=""; bestf=0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      f=$(cat "$p/scaling_max_freq" 2>/dev/null)
      [ -z "$f" ] && continue
      [ "$f" -gt "$bestf" ] 2>/dev/null && { bestf=$f; best=$p; }
    done
    [ -z "$best" ] && return 0
    cpus=$(cat "$best/affected_cpus" 2>/dev/null)
  else
    cpus=$TOUCH_IRQ_AFFINITY
  fi
  mask=0
  for c in $cpus; do mask=$((mask | (1 << c))); done
  hex=$(printf '%X' "$mask")
  if echo "$hex" >"/proc/irq/$irq/smp_affinity" 2>/dev/null; then
    log "触控 IRQ $irq 亲和性 -> $hex (CPU: $cpus)"
  else
    log "触控 IRQ $irq 亲和性设置失败(可能被内核接管)"
  fi
}

# ---- 触控持久档位(v1.5.0): boot/once 写一次, 看门狗不维护 ----
# 依据官方内核源码(v2 栈): chosen 档存在 ts 里, 亮屏 resume 自动重放;
# 系统/游戏助手改档属官方意图, 不对抗不反写; 充电插拔切 charging 表, 接受。
# 节点不存在(OTA 换栈)则跳过并记日志, 绝不盲写。详见 docs/touch-research-v1.5.md。
touch_level_write(){
  node=$1; want=$2
  [ "$want" = "-1" ] && return 0
  path=/proc/touchpanel/$node
  if [ ! -f "$path" ]; then
    log "触控节点不存在, 跳过: $path (OTA 可能换了触控栈)"
    return 0
  fi
  cur=$(tp_level "$node")
  if [ "$cur" = "$want" ]; then
    log "$node 已是 $want, 跳过"
    return 0
  fi
  if echo "$want" >"$path" 2>/dev/null; then
    log "$node ${cur:-?}->$want"
  else
    log "$node 写入失败(want=$want)"
  fi
}
# v1.6.1: 游戏模式开关. 节点内容形如 "0, high_frame_support:0,...", 首字段才是开关;
# 不能用 tp_level 比较. 本机 DTS 无 smooth/sensitive 联动, 写非 0 只发固件 GAME_ON.
touch_gs_write(){
  [ "$TOUCH_GAME_SWITCH" = "-1" ] && return 0
  path=/proc/touchpanel/game_switch_enable
  if [ ! -f "$path" ]; then
    log "game_switch_enable 不存在, 跳过 (OTA 可能换了触控栈)"
    return 0
  fi
  cur=$(gs_state)
  if [ "$cur" = "$TOUCH_GAME_SWITCH" ]; then
    log "game_switch_enable 已是 $TOUCH_GAME_SWITCH, 跳过"
    return 0
  fi
  if echo "$TOUCH_GAME_SWITCH" >"$path" 2>/dev/null; then
    log "game_switch_enable ${cur:-?}->$TOUCH_GAME_SWITCH"
  else
    log "game_switch_enable 写入失败(want=$TOUCH_GAME_SWITCH)"
  fi
}
apply_touch(){
  touch_level_write sensitive_level "$TOUCH_SENSITIVE_LEVEL"
  touch_level_write smooth_level "$TOUCH_SMOOTH_LEVEL"
  touch_gs_write
  touch_irq_affinity
}

# ---- 触控守护(v1.6.0): 独立进程, 不进刷新看门狗(单职责) ----
# 真机证据: 模块开机写入 4/1 后, 30 秒采样 sens/smooth 全是 0(ColorOS 改回厂商默认).
# 每个亮屏 tick 读档位, 不等于目标就写回并回读; 每分钟写回超过上限退避到下一分钟,
# 同因日志每分钟 ≤1 条, 避免和系统形成 1s 拉锯刷屏。
guard_alive(){
  [ -f "$GUARDF" ] || return 1
  p=$(cat "$GUARDF" 2>/dev/null)
  [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "apply.sh" "/proc/$p/cmdline" 2>/dev/null \
    && grep -q "guard" "/proc/$p/cmdline" 2>/dev/null
}
GT=""
# 同因日志每分钟 ≤1 条。强制写回(唯一明知会卡 20ms 的时刻)与每分钟上限(持续拉锯信号)
# 是 P2 诊断关键事件, 各自独立桶, 不与暂缓/写回日志互相吞掉; 其余共用 GT 桶(旧行为)。
glog(){
  now=$(date +%s)
  case "$1" in
    *强制写回*) last=${GTF:-0} ;;
    *上限*)     last=${GTC:-0} ;;
    *)          last=${GT:-0} ;;
  esac
  [ $((now - last)) -lt 60 ] && return 0
  case "$1" in
    *强制写回*) GTF=$now ;;
    *上限*)     GTC=$now ;;
    *)          GT=$now ;;
  esac
  log "触控守护: $*"
}
# ---- v1.6.2: 写回避让(报点活动检测) ----
# 不能用 fd_touch_count: 它受 face_detect_support 门控(本机 DTS 无此属性, 节点不创建;
# 即使存在也只统计人脸检测开启时上半屏中心区的手指, touchpanel_proc.c L6145)。
# 改用 /proc/interrupts 触摸 IRQ 计数差值: 读取不持 ts->mutex; 150ms 内计数增长 =
# 报点正在流动, 此时写 proc 会持 ts->mutex >=20ms 卡住报点线程(tp_irq_thread_fn 同锁)。
# 计数不涨 = 无报点流量(手指抬起, 或静止不出报点), 写回不会造成可感知卡顿。
touch_irq_sum(){
  grep -i touch /proc/interrupts 2>/dev/null | awk '
    { s=0; for (i=2; i<=NF; i++) { if ($i ~ /^[0-9]+$/) s+=$i; else break } total+=s }
    END { print total+0 }'
}
BUSY_TICK=-1; BUSY=0; DEFER=0; DEFER_TICK=-1
# 每 tick 最多探测一次(150ms), 结果按 tick 缓存; $tick 由 touch_guard 循环维护
touch_busy(){
  if [ "$BUSY_TICK" != "$tick" ]; then
    BUSY_TICK=$tick
    a=$(touch_irq_sum); sleep 0.15; b=$(touch_irq_sum)
    if [ "$b" -gt "$a" ] 2>/dev/null; then BUSY=1; else BUSY=0; fi
  fi
  [ "$BUSY" = "1" ]
}
# 写回门: 返回 0=允许写, 1=本轮跳过(跳过不计入 writes 上限)。
# defer 只在确有漂移要写回时累加, 每 tick 至多 +1; 连续避让达 TOUCH_GUARD_DEFER_MAX
# 强制写一次, 避免持续触控时永远不写回。log 模式不写节点, 不经过此门。
write_gate(){
  if ! touch_busy; then DEFER=0; return 0; fi
  if [ "$DEFER_TICK" != "$tick" ]; then DEFER=$((DEFER + 1)); DEFER_TICK=$tick; fi
  if [ "$DEFER" -ge "$TOUCH_GUARD_DEFER_MAX" ]; then
    DEFER=0
    glog "报点活跃连续 ${TOUCH_GUARD_DEFER_MAX} tick, 强制写回一次(持锁>=20ms)"
    return 0
  fi
  glog "报点活跃, 暂缓写回 ($DEFER/$TOUCH_GUARD_DEFER_MAX)"
  return 1
}
touch_guard(){
  case "${TOUCH_GUARD:-pin}" in
    off) log "TOUCH_GUARD=off, 触控守护不启动"; exit 0 ;;
  esac
  if [ "$TOUCH_SENSITIVE_LEVEL" = "-1" ] && [ "$TOUCH_SMOOTH_LEVEL" = "-1" ]; then
    log "两个触控档位都是 -1, 触控守护不启动"
    exit 0
  fi
  if guard_alive; then
    log "触控守护已存在(PID $(cat "$GUARDF")), 本实例退出"
    exit 0
  fi
  echo $$ >"$GUARDF"
  echo 0 >"$TOUCHF" 2>/dev/null
  log "触控守护启动 (mode=$TOUCH_GUARD 间隔=${TOUCH_GUARD_INTERVAL}s 上限=${TOUCH_GUARD_MAX_WRITES}/min 避让=${TOUCH_GUARD_DEFER_MAX}tick)"
  tick=0; on=1; writes=0; bucket=0; fallback=0; DEFER=0; DEFER_TICK=-1; BUSY_TICK=-1
  while :; do
    # 亮屏判断不必每秒 dumpsys: 每 10 tick(≈10s) 刷新一次
    if [ $((tick % 10)) -eq 0 ]; then
      if screen_on; then on=1; else on=0; fi
    fi
    if [ "$on" = "1" ]; then
      now=$(date +%s)
      if [ $((now / 60)) -gt "$bucket" ]; then bucket=$((now / 60)); writes=0; fi
      for pair in "sensitive_level:$TOUCH_SENSITIVE_LEVEL" "smooth_level:$TOUCH_SMOOTH_LEVEL"; do
        node=${pair%%:*}; want=${pair#*:}
        [ "$want" = "-1" ] && continue
        cur=$(tp_level "$node")
        [ "$cur" = "$want" ] && continue
        if [ "$TOUCH_GUARD" = "log" ]; then
          fallback=$((fallback + 1))
          echo "$fallback" >"$TOUCHF" 2>/dev/null
          glog "回退(仅记录): $node ${cur:-?}->$want"
          continue
        fi
        if [ "$writes" -ge "$TOUCH_GUARD_MAX_WRITES" ]; then
          glog "回退持续, 已达每分钟 ${TOUCH_GUARD_MAX_WRITES} 次上限, 本分钟不再写"
          continue
        fi
        write_gate || continue
        if echo "$want" >"/proc/touchpanel/$node" 2>/dev/null; then
          writes=$((writes + 1))
          fallback=$((fallback + 1))
          echo "$fallback" >"$TOUCHF" 2>/dev/null
          got=$(tp_level "$node")
          if [ "$got" = "$want" ]; then
            glog "已写回: $node ${cur:-?}->$want"
          else
            glog "写回未生效: $node want=$want got=${got:-?}"
          fi
        else
          glog "写回失败: $node want=$want (节点不可写)"
        fi
      done
      # 游戏模式(v1.6.1): 系统改回 0 时按同一上限写回; -1=不碰
      if [ "$TOUCH_GAME_SWITCH" != "-1" ]; then
        gcur=$(gs_state)
        if [ -n "$gcur" ] && [ "$gcur" != "$TOUCH_GAME_SWITCH" ]; then
          if [ "$TOUCH_GUARD" = "log" ]; then
            fallback=$((fallback + 1)); echo "$fallback" >"$TOUCHF" 2>/dev/null
            glog "游戏模式回退(仅记录): ${gcur}->$TOUCH_GAME_SWITCH"
          elif [ "$writes" -ge "$TOUCH_GUARD_MAX_WRITES" ]; then
            glog "游戏模式回退持续, 已达每分钟 ${TOUCH_GUARD_MAX_WRITES} 次上限"
          elif ! write_gate; then
            : # 报点活跃, 本轮暂缓(门内已记日志)
          elif echo "$TOUCH_GAME_SWITCH" >/proc/touchpanel/game_switch_enable 2>/dev/null; then
            writes=$((writes + 1)); fallback=$((fallback + 1)); echo "$fallback" >"$TOUCHF" 2>/dev/null
            glog "游戏模式已写回: ${gcur}->$TOUCH_GAME_SWITCH"
          else
            glog "游戏模式写入失败(game_switch_enable 不可写)"
          fi
        fi
      fi
    fi
    tick=$((tick + 1))
    if [ "$on" = "0" ]; then
      sleep 5
      tick=0
      BUSY_TICK=-1   # 灭屏跨周期后作废报点活动缓存, 亮屏重新探测
    else
      sleep "$TOUCH_GUARD_INTERVAL"
    fi
  done
}

# ---- 只记录不盲写: 未知格式节点留给后续调参 ----
# 真机实测(v1.5.0 探针): 这两个路径是目录不是文件, head -c 读目录永远为空;
# 改为枚举目录内文件名(仍不读内容不写入), 给后续调参留线索
discover(){
  for n in oplus_touch_boost oplus_frame_boost; do
    if [ -d "/proc/$n" ]; then
      log "发现 /proc/$n (目录): $(ls "/proc/$n" 2>/dev/null | tr '\n' ' ')"
    elif [ -e "/proc/$n" ]; then
      log "发现 /proc/$n=$(head -c 120 "/proc/$n" 2>/dev/null | tr '\n' ' ')"
    else
      log "发现 /proc/$n 不存在"
    fi
  done
}

do_apply(){
  save_backup
  apply_refresh
  apply_touch
  [ "$SF_1035_ENABLE" = "1" ] && sf_apply
  discover
  # 每次开机/手动应用都留一条策略快照, 排查时不用再猜"是副本错了还是没挂上"
  pv=$(policy_rate "$POLICY_SRC"); pmv=$(policy_rate "$MODDIR/my_product/etc/refresh_rate_config.xml")
  log "策略: 活文件=${pv:-none} 副本=${pmv:-none} (144 档应为 maxrefreshsettings=\"4\")"
  ds=$(dumpsys display 2>/dev/null)
  log "应用完成: peak=$(cur_peak) min=$(cur_min) 实测=$(render_hz "$ds")Hz mode=$(mode_id "$ds") changeable=$(refresh_changeable "$ds") sensitive=$(tp_level sensitive_level) smooth=$(tp_level smooth_level) gs=$(gs_state)"
}

alive(){
  # PID 存在且 cmdline 确实是本脚本 — 防止重启后 pidfile 残留/复用导致误判;
  # 排除 guard(触控守护)实例, 两个进程共用 apply.sh 入口
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "apply.sh" "/proc/$p/cmdline" 2>/dev/null \
    && ! grep -q "guard" "/proc/$p/cmdline" 2>/dev/null
}

# ---- 看门狗(v1.5.2): 验实测/模式/可切换性, 漂移时重写 refresh 设置 ----
# 亮屏稳态 WATCH_INTERVAL(默认10s) 只查 render_hz; 漂移先重写 min/peak(可切换范围)
# 触发系统重新 modeset, 2s 后复查; 1035 默认关闭(本机实测空操作)。连续失败退避
# 10→20→40→60s 封顶, 成功回稳态; 同因日志限频(每分钟≤1条); 灭屏 20s 长睡。
watch(){
  if alive; then
    log "守护进程已存在(PID $(cat "$PIDF")), 本实例退出"
    exit 0
  fi
  echo $$ >"$PIDF"
  log "看门狗启动 (稳态 ${WATCH_INTERVAL}s, 退避封顶 60s, SF1035=${SF_1035_ENABLE})"
  fails=0
  last_log=0
  while :; do
    if screen_on; then
      hz=$(render_hz)
      if [ "$hz" = "$TARGET_HZ" ]; then
        if [ "$fails" -gt 0 ]; then
          log "恢复正常: ${hz}Hz (此前连续失败 $fails 次)"
          fails=0
        fi
        sleep "$WATCH_INTERVAL"
      else
        fails=$((fails+1))
        now=$(date +%s)
        if [ $((now - last_log)) -ge 60 ]; then
          log "漂移: 实测 ${hz:-?}Hz != ${TARGET_HZ}Hz (mode=$(mode_id) changeable=$(refresh_changeable)), 重写刷新设置 (连续第 $fails 次)"
          last_log=$now
        fi
        apply_refresh quiet
        [ "$SF_1035_ENABLE" = "1" ] && sf_apply
        sleep 2
        hz2=$(render_hz)
        if [ "$hz2" = "$TARGET_HZ" ]; then
          log "复查通过: ${hz2}Hz"
          fails=0
          sleep "$WATCH_INTERVAL"
        else
          # 仍不达标: 若启用了 1035, 清缓存下轮重解析(防 OTA 后 id 变化)
          [ "$SF_1035_ENABLE" = "1" ] && SF_ID=""
          back=$((WATCH_INTERVAL * fails))
          [ "$back" -gt 60 ] && back=60
          sleep "$back"
        fi
      fi
    else
      sleep 20
    fi
  done
}

case "$1" in
  boot|daemon)
    mkdir -p "$DATA"
    # v1.5.1: 每次开机清空日志, 只保留本次开机内容; once(手动应用)不清, 保留守护历史
    : >"$LOGF" 2>/dev/null
    do_apply
    sleep 3
    verify_and_fix
    watch
    ;;
  once)
    mkdir -p "$DATA"
    trim_log
    do_apply
    sleep 3
    verify_and_fix
    ;;
  guard|touch-daemon)
    # v1.6.0: 触控守护独立进程(service.sh 拉起); 不写刷新设置、不碰策略
    mkdir -p "$DATA"
    trim_log
    touch_guard
    ;;
  status)
    # WebUI 只读字段。旧键名/顺序保持不变，只在末尾追加。
    # v1.6.2: display 信息一次 dump 供下面多个字段复用(原来 3 次 dumpsys display)
    ds=$(dumpsys display 2>/dev/null)
    echo "peak=$(cur_peak) min=$(cur_min)"
    echo "user_mode=$(cmd display get-user-preferred-display-mode 2>/dev/null)"
    echo "render=$(render_hz "$ds")Hz"
    echo "game_switch=$(gs_state)"
    echo "mode_active=$(printf '%s\n' "$ds" | grep -o 'mActiveModeId=[0-9]*' | head -n 1)"
    # 策略层状态: 活文件里的截断开关。v1.5.0 起本模块不自挂载, policy_bind 恒为 no
    # (保留键名兼容旧消费方; 历史版本残留 bind 仍可能被检出, 卸载时摘除)
    pv=$(policy_rate "$POLICY_SRC")
    echo "policy=${pv:-unknown}"
    if grep 'refresh_rate_config.xml' /proc/self/mountinfo 2>/dev/null | grep -q "${MODDIR##*/}"; then
      echo "policy_bind=yes"
    else
      echo "policy_bind=no"
    fi
    echo "daemon=$(alive && echo alive || echo dead)"
    echo "target_hz=${TARGET_HZ:-144}"
    echo "policy_enable=${POLICY_ENABLE:-1}"
    # v1.5.0 语义变更: 原 TOUCH_GAME_SWITCH 开关已废弃; 此键现表示"持久档位优化是否启用"
    # (sensitive/smooth 任一不为 -1 即 1), 供旧 WebUI 兼容; 新页面用 touch_sensitive/touch_smooth
    if [ "${TOUCH_SENSITIVE_LEVEL:--1}" != "-1" ] || [ "${TOUCH_SMOOTH_LEVEL:--1}" != "-1" ]; then
      echo "touch_switch=1"
    else
      echo "touch_switch=0"
    fi
    if [ -f "$MODDIR/disable" ]; then
      echo "module_disabled=1"
    else
      echo "module_disabled=0"
    fi
    # 覆盖副本自身的内容。副本=4 而 policy=3 => 元模块没接管 my_product(退化运行时方案);
    # 副本也是 3 => 副本没生成对(策略文件格式变了)
    pmv=$(policy_rate "$MODDIR/my_product/etc/refresh_rate_config.xml")
    echo "policy_module=${pmv:-none}"
    # v1.5.0 追加: 策略生效来源(meta=元模块已合并; runtime-only=未接管, SF+看门狗兜底; off=POLICY_ENABLE=0)
    if [ "${POLICY_ENABLE:-1}" != "1" ]; then
      echo "policy_source=off"
    elif [ "$pv" = "maxrefreshsettings=\"${POLICY_RATE:-4}\"" ]; then
      echo "policy_source=meta"
    else
      echo "policy_source=runtime-only"
    fi
    # v1.5.0 追加: 触控持久档位当前值(chosen 档读出; 空=节点不存在或不可读)
    echo "touch_sensitive=$(tp_level sensitive_level)"
    echo "touch_smooth=$(tp_level smooth_level)"
    # v1.5.2 追加: 系统是否允许切换刷新率(固定模式会卡 120); SF 1035 实验开关
    echo "refresh_changeable=$(refresh_changeable "$ds")"
    echo "sf_1035=${SF_1035_ENABLE:-0}"
    # v1.6.0 追加: 策略完整性与来源; 触控守护状态/目标档位/本次开机写回次数
    echo "policy_live_src=$(policy_src)"
    echo "default_rate_id=$(policy_attr defaultRateId "$POLICY_SRC")"
    echo "default_max_rate=$(policy_attr defaultMaxRate "$POLICY_SRC")"
    echo "win_override=$(policy_count 'enableWinOverride="false"' "$POLICY_SRC")/$(policy_count '<item ' "$POLICY_SRC")"
    echo "policy_complete=$(policy_complete)"
    echo "touch_target_sensitive=${TOUCH_SENSITIVE_LEVEL:--1}"
    echo "touch_target_smooth=${TOUCH_SMOOTH_LEVEL:--1}"
    echo "touch_guard=${TOUCH_GUARD:-pin}"
    echo "touch_daemon=$(guard_alive && echo alive || echo dead)"
    fb=$(cat "$TOUCHF" 2>/dev/null)
    echo "touch_fallback=${fb:-0}"
    ;;
  *)
    echo "用法: sh apply.sh boot|daemon|once|status"
    ;;
esac