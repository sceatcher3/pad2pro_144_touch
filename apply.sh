#!/system/bin/sh
# apply.sh — Pad 2 Pro 144Hz 修复 + 触控优化 核心
# 用法: sh apply.sh boot|daemon|once|status
# boot/daemon: 应用一次并进入看门狗循环  once: 应用一次  status: 打印当前状态

MODDIR=${0%/*}
DATA=/data/adb/p2p144
LOGF=$DATA/p2p.log
BK=$DATA/backup.conf
PIDF=$DATA/daemon.pid

# ---- 读取配置 ----
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
REFRESH_PEAK=${REFRESH_PEAK:-144.0}
REFRESH_MIN=${REFRESH_MIN:-144.0}
USER_REFRESH_RATE=${USER_REFRESH_RATE:-144}
OPLUS_REFRESH_KEY=${OPLUS_REFRESH_KEY:-4}
FORCE_USER_MODE=${FORCE_USER_MODE:-1}
FORCE_SF_MODE=${FORCE_SF_MODE:-1}
SF_FALLBACK_ID=${SF_FALLBACK_ID:-6}
TOUCH_GAME_SWITCH=${TOUCH_GAME_SWITCH:-1}
TOUCH_IRQ_AFFINITY=${TOUCH_IRQ_AFFINITY:-auto}
WATCH_INTERVAL=${WATCH_INTERVAL:-5}
TARGET_HZ=${TARGET_HZ:-144}
PEAK_I=${REFRESH_PEAK%%.*}
MIN_I=${REFRESH_MIN%%.*}

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOGF"; }
trim_log(){
  [ -f "$LOGF" ] || return 0
  sz=$(wc -c <"$LOGF")
  [ "$sz" -gt 102400 ] && { tail -n 300 "$LOGF" >"$LOGF.t"; mv "$LOGF.t" "$LOGF"; }
  return 0
}
screen_on(){ dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'; }
cur_peak(){ settings get system peak_refresh_rate 2>/dev/null; }
cur_min(){ settings get system min_refresh_rate 2>/dev/null; }
render_hz(){ dumpsys display 2>/dev/null | grep -o 'mActiveRenderFrameRate=[0-9]*' | head -n 1 | cut -d= -f2; }
gs_state(){ sed 's/,.*//' /proc/touchpanel/game_switch_enable 2>/dev/null | tr -d ' '; }

# ---- 备份原始值(仅首次) ----
save_backup(){
  [ -f "$BK" ] && return 0
  mkdir -p "$DATA"
  {
    echo "peak=$(cur_peak)"
    echo "min=$(cur_min)"
    echo "oplus_rate=$(settings get secure oplus_customize_screen_refresh_rate 2>/dev/null)"
    echo "user_refresh=$(settings get secure user_refresh_rate 2>/dev/null)"
    echo "game_switch=$(gs_state)"
  } >"$BK"
  log "已备份原始设置 -> $BK"
}

# ---- 刷新率三重锁 ----
apply_refresh(){
  settings put system peak_refresh_rate "$REFRESH_PEAK"
  settings put system min_refresh_rate "$REFRESH_MIN"
  settings put secure oplus_customize_screen_refresh_rate "$OPLUS_REFRESH_KEY" 2>/dev/null
  settings put secure user_refresh_rate "$USER_REFRESH_RATE" 2>/dev/null
  if [ "$FORCE_USER_MODE" = "1" ]; then
    # 竖屏参数优先(面板原生 2400x3392), 失败换横屏试
    cmd display set-user-preferred-display-mode 2400 3392 "$REFRESH_PEAK" 2>/dev/null
    um=$(cmd display get-user-preferred-display-mode 2>/dev/null)
    case "$um" in
      *null*|"") cmd display set-user-preferred-display-mode 3392 2400 "$REFRESH_PEAK" 2>/dev/null ;;
    esac
  fi
}

# ---- SF 层强切: 本机实测唯一有效硬手段 (ColorOS 策略层会把 render range 压回120) ----
sf_mode_id(){
  id=$(dumpsys SurfaceFlinger 2>/dev/null | grep -o 'id=[0-9]*, hwcId=[0-9]*, resolution=[0-9]*x[0-9]*, vsyncRate=144.00' | head -n 1 | sed 's/id=\([0-9]*\),.*/\1/')
  [ -n "$id" ] || id=$SF_FALLBACK_ID
  echo "$id"
}
sf_apply(){
  [ "$FORCE_SF_MODE" = "1" ] || return 0
  sid=$(sf_mode_id)
  service call SurfaceFlinger 1035 i32 "$sid" >/dev/null 2>&1
  log "SF 1035 强切 mode $sid"
}

verify_and_fix(){
  hz=$(render_hz)
  if [ "$hz" != "$TARGET_HZ" ]; then
    log "实测 ${hz:-?}Hz != ${TARGET_HZ}Hz, 重新应用(settings+SF)"
    apply_refresh
    sf_apply
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

apply_touch(){
  if [ "$TOUCH_GAME_SWITCH" = "1" ]; then
    st=$(gs_state)
    if [ "$st" != "1" ]; then
      echo 1 > /proc/touchpanel/game_switch_enable 2>/dev/null \
        && log "game_switch_enable $st->1" || log "game_switch_enable 写入失败"
    fi
  fi
  touch_irq_affinity
}

# ---- 只记录不盲写: 未知格式节点留给后续调参 ----
discover(){
  log "发现 oplus_touch_boost=$(head -c 120 /proc/oplus_touch_boost 2>/dev/null | tr '\n' ' ')"
  log "发现 oplus_frame_boost=$(head -c 120 /proc/oplus_frame_boost 2>/dev/null | tr '\n' ' ')"
}

do_apply(){
  save_backup
  apply_refresh
  apply_touch
  sf_apply
  discover
  log "应用完成: peak=$(cur_peak) min=$(cur_min) 实测=$(render_hz)Hz gs=$(gs_state)"
}

alive(){
  # PID 存在且 cmdline 确实是本脚本 — 防止重启后 pidfile 残留/复用导致误判
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "apply.sh" "/proc/$p/cmdline" 2>/dev/null
}

watch(){
  if alive; then
    log "守护进程已存在(PID $(cat "$PIDF")), 本实例退出"
    exit 0
  fi
  echo $$ >"$PIDF"
  log "看门狗启动 (间隔 ${WATCH_INTERVAL}s)"
  cycle=0
  while :; do
    if screen_on; then
      p=$(cur_peak); m=$(cur_min)
      pi=${p%%.*}; mi=${m%%.*}
      if [ "$pi" != "$PEAK_I" ] || [ "$mi" != "$MIN_I" ]; then
        log "漂移: peak=$p min=$m -> 重写"
        apply_refresh
      fi
      if [ "$TOUCH_GAME_SWITCH" = "1" ]; then
        st=$(gs_state)
        if [ "$st" != "1" ]; then
          echo 1 > /proc/touchpanel/game_switch_enable 2>/dev/null
          log "game_switch 漂移($st), 重写"
        fi
      fi
      cycle=$((cycle+1))
      verify_and_fix
      sleep "$WATCH_INTERVAL"
    else
      sleep 20
    fi
  done
}

case "$1" in
  boot|daemon)
    mkdir -p "$DATA"
    trim_log
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
  status)
    echo "peak=$(cur_peak) min=$(cur_min)"
    echo "user_mode=$(cmd display get-user-preferred-display-mode 2>/dev/null)"
    echo "render=$(render_hz)Hz"
    echo "game_switch=$(gs_state)"
    echo "mode_active=$(dumpsys display 2>/dev/null | grep -o 'mActiveModeId=[0-9]*' | head -n 1)"
    ;;
  *)
    echo "用法: sh apply.sh boot|daemon|once|status"
    ;;
esac
