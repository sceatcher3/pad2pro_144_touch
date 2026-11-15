#!/system/bin/sh
# apply.sh — Pad 2 Pro 144Hz 修复 + 触控优化 核心
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
# 用法: sh apply.sh boot|daemon|once|status
# boot/daemon: 应用一次并进入看门狗循环  once: 应用一次  status: 打印当前状态

MODDIR=${0%/*}
DATA=/data/adb/p2p144
LOGF=$DATA/p2p.log
BK=$DATA/backup.conf
PIDF=$DATA/daemon.pid
POLICY_SRC=/my_product/etc/refresh_rate_config.xml

# ---- 读取配置 ----
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
REFRESH_PEAK=${REFRESH_PEAK:-144.0}
REFRESH_MIN=${REFRESH_MIN:-120.0}
USER_REFRESH_RATE=${USER_REFRESH_RATE:-144}
OPLUS_REFRESH_KEY=${OPLUS_REFRESH_KEY:-4}
SF_FALLBACK_ID=${SF_FALLBACK_ID:-6}
SF_1035_ENABLE=${SF_1035_ENABLE:-0}
TOUCH_SENSITIVE_LEVEL=${TOUCH_SENSITIVE_LEVEL:-4}
TOUCH_SMOOTH_LEVEL=${TOUCH_SMOOTH_LEVEL:-1}
TOUCH_IRQ_AFFINITY=${TOUCH_IRQ_AFFINITY:-auto}
WATCH_INTERVAL=${WATCH_INTERVAL:-10}
TARGET_HZ=${TARGET_HZ:-144}

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOGF"; }
trim_log(){
  [ -f "$LOGF" ] || return 0
  sz=$(wc -c <"$LOGF")
  [ "$sz" -gt 102400 ] && { tail -n 300 "$LOGF" >"$LOGF.t"; mv "$LOGF.t" "$LOGF"; }
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
render_hz(){ dumpsys display 2>/dev/null | grep -o 'mActiveRenderFrameRate=[0-9]*' | head -n 1 | cut -d= -f2; }
mode_id(){ dumpsys display 2>/dev/null | grep -o 'mActiveModeId=[0-9]*' | head -n 1 | cut -d= -f2; }
refresh_changeable(){ dumpsys display 2>/dev/null | grep -o 'mRefreshRateChangeable: [a-z]*' | head -n 1 | awk '{print $2}'; }
gs_state(){ sed 's/,.*//' /proc/touchpanel/game_switch_enable 2>/dev/null | tr -d ' '; }
tp_level(){ cat "/proc/touchpanel/$1" 2>/dev/null | tr -d ' \n'; }
# 策略文件里的截断开关(取最后一个是真正的总开关; 头部注释里那个是过时的)
policy_rate(){ grep -o 'maxrefreshsettings="[0-9]*"' "$1" 2>/dev/null | tail -n 1; }

# ---- 备份原始值(仅首次) ----
# v1.5.0: 不再备份 game_switch(本模块已不写它); 新增 sensitive/smooth 两档位。
# 旧版 backup.conf 里的 game_switch 行由 uninstall.sh 兼容还原。
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
  hz=$(render_hz); mid=$(mode_id); ch=$(refresh_changeable)
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
apply_touch(){
  touch_level_write sensitive_level "$TOUCH_SENSITIVE_LEVEL"
  touch_level_write smooth_level "$TOUCH_SMOOTH_LEVEL"
  touch_irq_affinity
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
  log "应用完成: peak=$(cur_peak) min=$(cur_min) 实测=$(render_hz)Hz mode=$(mode_id) changeable=$(refresh_changeable) sensitive=$(tp_level sensitive_level) smooth=$(tp_level smooth_level)"
}

alive(){
  # PID 存在且 cmdline 确实是本脚本 — 防止重启后 pidfile 残留/复用导致误判
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "apply.sh" "/proc/$p/cmdline" 2>/dev/null
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
  status)
    # WebUI 只读字段。旧键名/顺序保持不变，只在末尾追加。
    echo "peak=$(cur_peak) min=$(cur_min)"
    echo "user_mode=$(cmd display get-user-preferred-display-mode 2>/dev/null)"
    echo "render=$(render_hz)Hz"
    echo "game_switch=$(gs_state)"
    echo "mode_active=$(dumpsys display 2>/dev/null | grep -o 'mActiveModeId=[0-9]*' | head -n 1)"
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
    echo "refresh_changeable=$(refresh_changeable)"
    echo "sf_1035=${SF_1035_ENABLE:-0}"
    ;;
  *)
    echo "用法: sh apply.sh boot|daemon|once|status"
    ;;
esac