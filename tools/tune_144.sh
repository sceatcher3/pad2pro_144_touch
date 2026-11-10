#!/system/bin/sh
# tune_144.sh — 逐项试验: 找出能把实测刷新率翻到 144 的杠杆
# 在 KSU 终端运行:  sh /sdcard/Download/Code/Module/tune_144.sh
# 详细诊断自动存 /sdcard/Download/p2p_diag.txt (发回给 AI 分析)

LOG=/sdcard/Download/p2p_diag.txt
: >"$LOG"
out(){ echo "$*"; echo "$*" >>"$LOG"; }
hz(){ dumpsys display 2>/dev/null | grep -o 'mActiveRenderFrameRate=[0-9]*' | head -n 1 | cut -d= -f2; }
check(){
  sleep 2
  h=$(hz)
  a=$(dumpsys display 2>/dev/null | grep -o 'mActiveModeId=[0-9]*' | head -n 1)
  out "  -> render=${h:-?}Hz $a"
  [ "$h" = "144" ]
}

out "===== S0 基线诊断 $(date '+%H:%M:%S') ====="
out "--- settings (refresh 相关) ---"
settings list system  2>/dev/null | grep -iE 'refresh' >>"$LOG"
settings list secure  2>/dev/null | grep -iE 'refresh' >>"$LOG"
settings list global  2>/dev/null | grep -iE 'refresh' >>"$LOG"
out "--- dumpsys display 关键行 ---"
dumpsys display 2>/dev/null | grep -E 'mActiveModeId|mUserPreferredModeId|mDefaultModeId|mDisplayModeSpecs|mActiveRenderFrameRate|peakRefreshRate|frameRateCategory' >>"$LOG"
out "--- SurfaceFlinger ---"
dumpsys SurfaceFlinger 2>/dev/null | grep -E 'peak-refresh-rate|FPS|renderRate|desiredDisplayModeSpecs' >>"$LOG"
out "--- 内核 /sys/kernel/oplus_display ---"
ls /sys/kernel/oplus_display/ >>"$LOG" 2>&1
cat /sys/kernel/oplus_display/dump_info >>"$LOG" 2>&1
out "--- logcat 尾部(刷新率相关) ---"
logcat -d -t 400 2>/dev/null | grep -iE 'refreshrate|DisplayMode|ModeDirector' >>"$LOG"

# 确保模块设置在位
settings put system peak_refresh_rate 144.0
settings put system min_refresh_rate 144.0
cmd display set-user-preferred-display-mode 2400 3392 144.0 2>/dev/null

out "===== 基线实测 ====="
check
h=$(hz)
if [ "$h" = "144" ]; then
  out ">>> 基线已是 144Hz — 之前只是检测太早, 一切正常!"
  dumpsys display >>"$LOG" 2>&1
  exit 0
fi

out "===== T1: oplus_refreshrate_override 1 -> 0 ====="
settings put secure oplus_refreshrate_override 0
if check; then out ">>> T1 生效! 方案 = 关闭 oplus_refreshrate_override"; dumpsys display >>"$LOG" 2>&1; exit 0; fi

out "===== T2: min=0.0 只留 peak=144 (排除 min==max 干扰) ====="
settings put system min_refresh_rate 0.0
if check; then out ">>> T2 生效! 方案 = peak 144 + min 0"; dumpsys display >>"$LOG" 2>&1; exit 0; fi

out "===== T3: oplus_customize_screen_refresh_rate 4 -> 7 (MAX档?) ====="
settings put secure oplus_customize_screen_refresh_rate 7
if check; then out ">>> T3 生效! 方案 = oplus键改 7"; dumpsys display >>"$LOG" 2>&1; exit 0; fi

out "===== T4: SF 1035 强切 SF-mode id 6 (=144) ====="
service call SurfaceFlinger 1035 i32 6 >/dev/null 2>&1
if check; then out ">>> T4 生效! 方案 = SF1035 强切(需并入看门狗)"; dumpsys display >>"$LOG" 2>&1; exit 0; fi

out "===== T5: peak=240 (defaultPeakRefreshRate=240 线索) ====="
settings put system peak_refresh_rate 240.0
if check; then out ">>> T5 生效! 方案 = peak 240"; dumpsys display >>"$LOG" 2>&1; exit 0; fi

out "===== 全部未命中: 还原默认并保存完整 dumpsys 供分析 ====="
settings put system peak_refresh_rate 144.0
settings put system min_refresh_rate 144.0
settings put secure oplus_refreshrate_override 1
settings put secure oplus_customize_screen_refresh_rate 4
dumpsys display >>"$LOG" 2>&1
dumpsys SurfaceFlinger >>"$LOG" 2>&1
out ">>> 请把 $LOG 发回给 AI 深入分析"
