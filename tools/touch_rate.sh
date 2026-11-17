#!/system/bin/sh
# touch_rate.sh — 只读诊断: 实测触控报点率(Hz)  (v1.6.2)
#
# 原理: 触控每上报一帧都会触发一次触摸 IRQ。读 /proc/interrupts 里 `touch-00` 那一行的
#   计数, 采样 N 秒求差 = 每秒上报次数。不依赖 getevent, 也就没有 stdio 缓冲/被 kill 丢尾
#   的问题(旧思路用 getevent 管道统计, 短采样会拿不到数据, 已弃用)。
#   本脚本不写任何节点、不改任何设置。
#
# 用法(root 或 shell):
#   sh tools/touch_rate.sh [采样秒数]      # 默认 5
#
# 怎么测才有意义:
#   - 采样期间**手指必须持续滑动**(画圈/来回拖); 静止时触控不出报点, 测到 0 是正常的。
#   - 先测 gs=0, 再测 gs=1:
#       su -c 'kill $(cat /data/adb/p2p144/guard.pid)'          # 先停守护, 否则 1s 内被改回
#       su -c 'echo 0 > /proc/touchpanel/game_switch_enable'; sh tools/touch_rate.sh 5
#       su -c 'echo 1 > /proc/touchpanel/game_switch_enable'; sh tools/touch_rate.sh 5
#     两次 avg 差多少, 就是 GAME_ON 对报点率的实际效果。
#   - 再分别测「慢速画圈」和「快速甩动」: 有的固件按手指速度自适应切档。
#
# 判读: 120Hz≈8.3ms/帧, 240Hz≈4.2ms, 288Hz≈3.5ms, 540Hz≈1.9ms。
# 用户真机观察(2026-11-18): 报点率与显示刷新率绑定≈2×(144Hz 显示→≈288Hz);
# 540Hz 采样仅 90Hz 显示档可达, 与保 144 显示互斥。gs=0/1 两态差异仍待受控实测。

DUR=${1:-5}
case "$DUR" in ''|*[!0-9]*) DUR=5 ;; esac
[ "$DUR" -ge 1 ] 2>/dev/null || DUR=5
[ "$DUR" -le 60 ] 2>/dev/null || DUR=60

# 所有 CPU 列求和; 行格式 `288: 123 0 0 ... GICv3 162 Level touch-00`
irq_sum(){
  grep -i touch /proc/interrupts 2>/dev/null | awk '
    { s=0; for (i=2; i<=NF; i++) { if ($i ~ /^[0-9]+$/) s+=$i; else break } total+=s }
    END { print total+0 }'
}

echo "== 当前状态 =="
for n in sensitive_level smooth_level; do
  f="/proc/touchpanel/$n"
  if [ -f "$f" ]; then echo "  $n = $(cat "$f" 2>/dev/null | tr -d ' \n')"; else echo "  $n = (不存在)"; fi
done
if [ -f /proc/touchpanel/game_switch_enable ]; then
  gsraw=$(cat /proc/touchpanel/game_switch_enable 2>/dev/null | tr -d '\n')
  # 首字段才是开关(与 apply.sh gs_state 同口径), 整串附后供排查
  echo "  game_switch_enable = $(echo "$gsraw" | sed 's/,.*//' | tr -d ' ')  [$gsraw]"
else
  echo "  game_switch_enable = (不存在)"
fi
echo "  (game_switch 首字段 1 = 固件 GAME_ON / 高触控轮询率模式)"

LINE=$(grep -i touch /proc/interrupts 2>/dev/null | head -n 1)
if [ -z "$LINE" ]; then
  echo "找不到触摸 IRQ 行(/proc/interrupts 里没有 touch), 无法测量"; exit 1
fi
# 计数对全部匹配行求和, IRQ 号也列出全部匹配行, 避免多行时计数混源而只显示首行号
IRQS=$(grep -i touch /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | tr '\n' ' ')
before=$(irq_sum)
if [ -z "$before" ]; then echo "读取 IRQ 计数失败"; exit 1; fi

echo "== 触摸 IRQ $IRQS采样 ${DUR}s —— 现在开始用手指持续滑动 =="
sleep "$DUR"
after=$(irq_sum)
delta=$((after - before))
[ "$delta" -lt 0 ] 2>/dev/null && delta=0

awk -v d="$delta" -v t="$DUR" -v a="$before" -v b="$after" 'BEGIN{
  printf "IRQ 计数 %d -> %d, 差值 %d / %ds\n", a, b, d, t;
  if (d <= 0) {
    printf "结果: 0 次上报 —— 采样期间没有滑动(或屏幕灭/守护刚写回), 重测一次\n";
    exit 0;
  }
  hz = d / t; ms = t * 1000 / d;
  printf "结果: %.1f 次/秒  (平均 %.1f ms/帧)\n", hz, ms;
  printf "判读: 120Hz≈8.3ms  240Hz≈4.2ms  288Hz≈3.5ms(2×144)  540Hz≈1.9ms(仅90Hz显示档)\n";
  if (hz < 60)        printf "      偏低: 可能滑动不连续, 或该状态固件降频\n";
  else if (hz < 200)  printf "      ≈120-180Hz 档\n";
  else if (hz < 400)  printf "      ≈240-360Hz 档(144Hz 显示下 2× 绑定预期≈288)\n";
  else if (hz < 480)  printf "      ≈360-480Hz: 高于 2×144=288, 未达 540, 复测确认\n";
  else                printf "      ≈540Hz 档(用户观察仅 90Hz 显示档可达; 144 显示下测到请复测)\n";
}'