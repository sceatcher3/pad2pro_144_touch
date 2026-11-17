# Agent 分支笔记

AGENTS.md 只留每个分支都需要的通用约定；本文件按分支存放细节与踩坑证据，改到哪块读哪节。
一手调研归档：触控接口 → [touch-research-v1.5.md](touch-research-v1.5.md)；540Hz 触控率 → [touch-rate-540-design.md](touch-rate-540-design.md)；守护与策略补全的设计推理 → [v1.6-pin-design.md](v1.6-pin-design.md)。

## 策略层

### 元模块与挂载

- 元模块（metamodule）是 KSU 的挂载基础设施：`module.prop` 带 `metamodule=1`（meta-overlayfs / Hybrid Mount / Magic Mount-rs / Mountify 等），同一时间只能装一个，负责把普通模块的分区目录合并进系统；**没装元模块则所有模块都不挂载**（[KSU 官方文档](https://kernelsu.org/guide/metamodule.md)）。
- 挂载方式不统一：overlay（mountinfo 不可见）、magic mount/bind（可见）、VFS/nomount（无真实挂载）；有的元模块默认不接管 `my_product`（Magic Mount-rs 要 `extra_mount=["my_product"]`）。判断生效只看活文件内容 `maxrefreshsettings`，不看 `mount` 输出、不依赖任何元模块 CLI。
- **本模块不自挂载**（v1.5.0 起 bind 兜底与 `POLICY_MOUNT` 键已整体删除）。没接管时活文件停在 3 是**预期退化**（`policy_source=runtime-only`），运行期 peak=144/min=120 + 看门狗保 144。别把 bind 加回来：历史上它与元模块叠加顺序互相盖（v1.4.2 的坑），维护成本大于收益。`uninstall.sh` 的 umount 仅清历史版本残留。
- 其他普通模块可能盖住本模块副本：真机实测 extreme_gt（解锁帧率/温控的普通模块）自己 bind 同一策略文件叠在合并层之上。属正常竞争——只看活文件结果（=4 达标），不区分来源、不对抗。`policy_source=meta` 语义是「外部已接管」（含元模块合并或其他模块 bind），不特指元模块。
- 演进备查：v1.2 手动 bind → v1.3.3 只交元模块 → v1.3.5 标准目录+bind 兜底 → v1.4.1 修 sed `/g` → v1.4.2 bind 判据看活文件 → v1.5.0 删全部自挂载。策略字段语义参考 github.com/barsikus007/OnePlus15-165HZ。

### 副本生成（sed）

- 策略文件是**单行 XML**：`maxrefreshsettings` 在头部注释里也出现一次，`sed s///` 必须带 `/g`，否则只改到注释、尾部总开关仍是 3。
- 词汇表：`rateId` 0=未指定 1=90 2=60 3=120 4=144；文件头注释过时，尾部 `<config maxrefreshsettings="3">` 才是真正的 120 截断总开关。
- `defaultRateId` 是大写 R，必须单独一条 sed，不能被小写 `s/rateId=/` 顺带匹配。活文件里可能根本没有该属性（extreme_gt 接管后就没有），补丁重点是 `defaultMaxRate="144"`（缺省时策略按 120 处理 app 切换 boost/浮窗）+ 给每个 `<item>` 加 `enableWinOverride="false"`（不关时应用可把频率往下 revise，掉 120 再被看门狗拉回）。
- 副本一律先写临时文件再 `cat` 原地覆盖；`sed 源 > 副本` 在源已是本模块副本时会把文件截成空。生成后回读尾部校验并写 `post_fs.log`；**校验通过才落盘**，失败保留旧副本。
- `POLICY_ENABLE=0` 时 `post-fs-data.sh` 必须同时 `rm -rf $MODDIR/my_product`，否则残留副本仍被合并、开关看似无效。元模块可能先于脚本完成合并，关开关后旧副本可能撑完这一轮开机——别为此加同步等待。

### 生效归因

- `policy_source`：`meta`=外部已接管 / `runtime-only`=未接管 / `off`=POLICY_ENABLE=0。
- `policy_module` 是副本自身内容，区分「副本没改对」和「没被接管」：副本=4 而 policy=3 → 无外部接管；都=3 → 副本没生成对（看 `post_fs.log`）。
- 活文件可能与副本**逐字节相同**（200296 B / 2142 item，sed 幂等），内容判断不了来源；归因只看 `policy_live_src`（mountinfo root 字段解析的模块名）+ `policy_complete`。
- `policy_complete=1` 才算策略生效（`maxrefreshsettings`/`defaultMaxRate`/winOverride，及 `defaultRateId` 若存在，四项达标）；别只看 `maxrefreshsettings=4` 就报「已生效」。=0 时看 `post_fs.log` 是校验失败还是没被合并（后者策略层救不了，只能靠运行时）。
- `ipePencilRateId="3"`（手写笔锁 120）刻意保留不动，避免手写笔管线异常。

## 刷新率层

- **min=peak 锁死 modeset**（v1.5.2 实锤）：AOSP `DisplayModeDirector$SettingsObserver` 判据 `changeable = (max-min>1 && max>60)`；min=peak=144 → `mRefreshRateChangeable=false`，系统投票/specs 都 144，但亮屏 resume 后停 120 不再切。设置页「高刷新率」也可能写成 144/144；选「智能切换」后实测 `mActiveModeId=7`。默认 min=120（或 10），不要 144。
- **ksu 域写入被拒**（v1.5.2 实测）：`settings get/put`、`cmd settings/display`、`input keyevent` 都报 `Failed transaction (2147483646)`；`su 2000` 仍是 `u:r:ksu:s0`，没用；`content query` 能读，`content update` 返回 0 但 0 行。唯一可靠写入是系统设置 App。`setting_put` 三级回退（`settings` → `runcon u:r:shell:s0 settings` → `content update`）+ `setting_get` 回读，失败只记日志、不假装成功；状态页提示用户去设置选「智能切换」。
- **SF 1035 本机空操作**（v1.5.2 实测）：`service call SurfaceFlinger 1035 i32 6` 返回 `Parcel(NULL)`，`dumpsys SurfaceFlinger | grep debugDisplayModeByBackdoor` 的 pid/name 始终 0/空，`i32 -1` 返回 Invalid argument，模式不变；之前看到的 144 来自默认模式/系统自身切换，不是 1035 的功劳。默认 `SF_1035_ENABLE=0`，仅其他 ROM/旧版本确认有效时才开；开启时 id 从 `dumpsys SurfaceFlinger` 抓 `vsyncRate=<TARGET_HZ>.00`，缓存 `SF_ID`，抓不到用 `SF_FALLBACK_ID`。
- SF 侧 1035 参数 id 6 与 display 侧 `mActiveModeId=7` **不是同一编号空间**（id 6 对应 144 档 id 7），别把数字当矛盾。
- 看门狗节奏（v1.5.2）：稳态 `WATCH_INTERVAL`（默认 10s）查 render_hz；漂移时 `apply_refresh quiet` 重写 min/peak 触发 modeset，2s 复查；`SF_1035_ENABLE=1` 才补 1035；连续失败退避 `WATCH_INTERVAL*fails` 封顶 60s，成功归零；同因日志 `date +%s` 限频每分钟 ≤1 条；灭屏 20s。
- 面板档位（CSOT 3392x2400）：30/48/50/60/90/120/144，内核默认档就是 144（id 7）。

## 触控层

先读一手归档 [touch-research-v1.5.md](touch-research-v1.5.md)（栈身份/节点矩阵/档位表）；动触控率另读 [touch-rate-540-design.md](touch-rate-540-design.md)。本节只放操作约定。

- **档位方向**（真机手感确认）：`sensitive_level` 发固件 `EVENTBUFFER_EXT_JITTER_LEVEL(0x0C)`，raw 越小越灵敏/抗抖越弱；`smooth_level` 发 `EXT_SMOOTH_LEVEL(0x0D)`，raw 越大越平滑。依据：DTS 单调数组 + 充电表整体抬高 raw（同档更保守）。默认 2/3 = raw 15/96；4/1（raw 10/32）是「最灵敏/最少平滑」端，FPS 准星微抖。手感只改 config 默认值，不改代码逻辑。`pen_sensitive_level` 场景键动手写笔管线，刻意不碰。
- **档位会被 ColorOS 改回 0**（v1.6.0 实测 30 秒轨迹 30/30 次 sens=0 smooth=0），写一次保不住 → 独立守护 `apply.sh guard`（`TOUCH_GUARD=pin` 默认写回，首次排查可切 `log` 只记录）。守护只写 proc 节点、**不写 `touch_scene_para`**：把 scene 的「最后值」改成目标档，反而让系统的 0 生效。
- 守护节奏：每 `TOUCH_GUARD_INTERVAL`（默认 1s）读档位，不等于目标就写回并回读；每 10 tick 才 `dumpsys power` 判亮屏；灭屏 sleep 5；每分钟写回上限 `TOUCH_GUARD_MAX_WRITES`（默认 6），超限退避到下一分钟；同因日志每分钟 ≤1 条；`off` 不启动。v1.6.1 起同一循环维护 `game_switch_enable`（比较首字段而不是整串；写回共用每分钟上限）。v1.6.2 起写回前经报点活动避让门（下条）。
- **每次写 proc 持 `ts->mutex` ≥20ms**（源码核实：level 写路径持锁跨 `lv_set`；`nvt_extend_cmd2_store()`/`nvt_cmd_store()` retry=5×`msleep(20)` → 正常 20ms 最坏 100ms；`tp_irq_thread_fn()` 同一把锁，`int_mode` 默认 BANNABLE）。**`fd_touch_count` 不能用**：受 `face_detect_support` 门控（proc 节点表 L6145），本机 DTS 无该属性 → 节点不创建；即使存在也只统计人脸检测开启时上半屏中心区手指（`touch_count` 低 4 位 = `finger_num_center`）。本机没有任何不持锁就能读手指/报点活动的现成 proc 节点（`irq_depth` 读的是 IRQ 禁用深度+GPIO 电平；debug_info 类全持锁还 disable_irq）。**v1.6.2 已实现避让**：写回前用 `/proc/interrupts` 触摸 IRQ 计数差值（150ms 窗口、不持 `ts->mutex`）探测报点活动，活跃则暂缓（不计入 writes 上限），连续 `TOUCH_GUARD_DEFER_MAX`（默认 10）tick 后强制写一次；强制写回与上限日志各自独立节流桶（各 ≤1 条/分钟）。真机偶发跳帧先看 `touch_fallback` 是否在涨、日志有无「强制写回」，再考虑 `TOUCH_GUARD=log`。
- **game_switch 操作结论**（一手依据见 touch-research-v1.5.md）：本机（NT36536/v2 栈/erhai DTS）写非 0 只发固件 GAME_ON 命令，无 smooth/sensitive/major_rate 副作用；v2 栈灭屏**有条件**发 MODE_GAME,false（`!is_incell_panel || (black_gesture_support && gesture_enable>0)`；本机 incell → 仅双击手势开启时才发 GAME_OFF），不清 noise_level，亮屏自动恢复游戏模式与档位（不需要防灭屏丢失的看门狗）；common 层只做 `value>0` 布尔判断（内核按十六进制解析 `kstrtoint(buf,16)`），社区 node 26 魔法值档位表属闭源 touchDaemon framework_mode 路径，本机无该节点，别照抄。v1.6.1 起按用户要求写 1（`TOUCH_GAME_SWITCH` 默认 1，`-1` 不碰，`0` 强制关）；可能与游戏助手互写，日志记「游戏模式回退」，频繁就设 `-1`。`game_switch_enable=1` 就是系统侧「高触控轮询率」（HighTouchPollingRate），LineageOS `hardware_oplus` 同名 HAL 写的就是它。
- 充电插拔切厂商 charging 表（**仅 sensitive 有 charging 表**，同档 raw 更大更保守；DTS 无 smooth-level-charging，smooth 充电复用普通表），接受不补写；游戏助手进游戏改档属官方意图，不对抗（「零拉锯」的含义）。
- **IRQ 编号每次开机都变**（288→343→279→282…），必须动态从 `/proc/interrupts` 解析；匹配关键字 `touch`（`touch-00`，GPIO 162），不是 `touchpanel`；亲和性按 `smp_affinity` 十六进制掩码写，默认绑最强 CPU 簇（policy6，max 3.28GHz；实测默认 378 万次中断全砸 CPU0 小核）。
- `/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` 是**目录不是文件**（旧版 `head -c` 读目录永远为空），格式未知（官方内核分支 grep 不到创建者，可能闭源 ko），`discover()` 只枚举文件名记日志、不盲写。同名官方实现实为 sysfs `cpu*/touch_boost/`（CPU 提频）与 `/proc/sys/fbg/`（调度 boost），都不是触控报点；内核自带 `touch_boost_cpufreq` 保持原样不动。
- **540Hz**：面板规格上限 540Hz、默认 120Hz；内核没有速率旋钮——`report_rate` 节点需 `report_rate_v2_support` + `ts_ops->report_rate`（本机都无 → 不创建），`high_frame_rate:<v><t>` 载荷需 `set_high_frame_rate` + `high_frame_rate_support`（本机都无 → 空操作）；`*_sys_touch_scene_config.xml` 可挂载但场景通道只认 5 个键（`screen_lock_mode`/`sensitive_level`/`set_package_type`/`pen_sensitive_level`/`touch_leave_jitter`），无速率键。唯一用户态入口 `game_switch_enable=1`。**用户真机观察（2026-11-18）：报点率≈2×显示刷新率（144→≈288Hz），540Hz 仅 90Hz 显示档可达 → 与保 144 互斥，144 下现实上限≈288Hz**；gs=0/1 两态用 `tools/touch_rate.sh` 受控实测确认。NT36536 扩展命令表没有 `REPORT_RATE(0x14)`；社区 hbp/node-182 模块属别的触控栈，照抄会断触。完整证据链见 touch-rate-540-design.md。

## WebUI

- **只读**：不写 `config.conf`、不触发 `apply.sh once`、不改系统设置；只读 status、复制、导出日志到 `/sdcard/Download/`。
- **日志不渲染**：页面只显示 `p2p.log`/`post_fs.log` 的字节数与最后写入时间；日志内容一律**设备侧**合成（`{ ... } > 文件`），不经 `exec` 的 stdout——桥有长度上限，整份 `cat` 回来会被静默截断（旧版「日志页空白」的根因）。导出失败自动回退 `/data/local/tmp/`，toast 必须报出实际路径。
- **零依赖**：单文件、内联 CSS/JS、无 CDN/外部字体/图标；只做深色模式。
- **命令写死**：所有 `exec` 命令由页面常量拼接，只有模块目录经 `shq()` 加引号；不接受页面输入拼 shell。
- **渲染安全**：状态一律 `textContent`，禁止 `innerHTML`。
- **反馈**：所有可点控件都有 toast（动作+结果）；自动刷新静默，失败走红条 banner，不弹 toast。
- **模块目录**：不写死路径；先按 `module.prop` 的 `id` 扫 `/data/adb/modules/*`，回退 `/data/adb/modules/pad2pro_144_touch`。
- **桥差异**：KSU `exec` 返回 `{errno,stdout,stderr}`，APatch 返回字符串；适配层统一，命令末尾追加 `__RC=$?` 取真实退出码；不依赖 `ksu.spawn`。
- **权限**：`webroot` 的权限/SELinux 由管理器设置，不在 `customize.sh` 里 chmod。
- **状态判定（两卡结果导向）**：刷新率卡 render=120 且 `refresh_changeable=false` → warn「固定刷新率模式」+ 提示去设置选「智能切换」；render 达标 → good。触控卡按**目标 vs 实际**：`touch_target_*` 与 `touch_sensitive/smooth` 一致 → good；不一致 → warn「目标 2 / 3 · 守护写回中」；节点不可读 → warn。策略行：`policy=4` 且 `policy_complete=1` →「策略已生效」；`policy=4` 属性不全 →「策略属性不全」；`policy_source=runtime-only` →「策略未接管（运行时方案）」。`game_switch` 不上页面；卡片 detail 一律人话，不放 key=value 技术黑话。
- **布局**：两卡（实测刷新率/触控档位，<560px 单列）+ 一行「看门狗 · 策略」小字；工具栏只留「更新于 + 刷新」；导出区 = 日志大小/时间两行 + 两按钮（导出日志 primary + 复制状态），无说明行；顶栏 = 模块名 + 版本 + 总体徽章；无页脚、无原始状态折叠面板（key=value 只进剪贴板/导出文件）。
- **验收**：开发环境没有 `/data/adb`，最终以真机模块卡 WebUI 打开为准；改完先跑 `sh -n` 和页面 JS 语法检查。无 bridge 时只显示提示页，属正常。

## 日志与导出

- 运行日志：`/data/adb/p2p144/p2p.log`（>100KB 自动截断）、`post_fs.log`、备份 `backup.conf`。不写 `/sdcard`；用户导出例外（WebUI / `tools/check_v12.sh`）→ `/sdcard/Download/`，文件名前缀 `pad2pro-`。
- **日志每次重启清空**（v1.5.1）：`post-fs-data.sh` 清 `post_fs.log`，`apply.sh boot/daemon` 清 `p2p.log`，`once` 不清；导出文件头部带 `boot_only=1` 标记。
- **导出默认只出摘要**：`pad2pro-doctor-*.txt` 的日志各只 `tail -n 200`、策略只出 config/来源/计数；`tools/diag_pin.sh` 默认对三个策略文件与显示配置只出 sha256/config/计数/前 15 行（旧版全文 64KB×3 = 245KB）；`PAD2PRO_DIAG_FULL=1` 才出全文。
- 改导出格式时保留 `boot_only=1` 与落盘路径回执（`__OK=`/`__SIZE=`），WebUI 靠它报 toast。

## 真机验收清单

1. **策略补全**：重启 → `status` 里 `policy=4`、`default_max_rate=144`、`win_override=<false数>/<item数>`、`policy_complete=1`、`policy_live_src` 指向实际生效模块。=0 时看 `post_fs.log` 是「校验失败」还是「副本没被合并」——后者策略层救不了，只能靠运行时。
2. **触控守护**：`daemon=alive` 且 `touch_daemon=alive`；亮屏 1 分钟 `touch_sensitive=2 touch_smooth=3 game_switch=1` 应保持；`touch_fallback` 增长说明期间被改过又写回；触控日志每分钟 ≤1 条（没回退就不刷屏）。
3. **看门狗/固定模式**：亮屏静置 10 分钟 `p2p.log` 不刷屏（稳态无日志）；设置切「高刷新率」或手动 min=144 制造固定模式，≤10s 内重写设置、2s 复查；仍不达标时退避递增且日志每分钟 ≤1 条；切回「智能切换」恢复 144。
4. **灭亮屏**：灭屏 1 分钟再亮屏 render 仍 144；`cat /proc/touchpanel/sensitive_level /proc/touchpanel/smooth_level` 档位保持（内核自恢复 + 守护兜底）。
5. **充电插拔**：回读档位——charging 表手感略保守，chosen 档仍由守护保持；render 不受影响。
6. **游戏进出**：系统改档时守护 ≤1s 写回（`TOUCH_GUARD=pin`、报点不活跃时）；报点活跃时暂缓至 `TOUCH_GUARD_DEFER_MAX` tick 强制写回（日志见「暂缓/强制写回」，各 ≤1 条/分钟）；观察系统原始行为临时切 `TOUCH_GUARD=log` 跑一个周期。
7. **A/B 手感与报点率**：先 `kill $(cat /data/adb/p2p144/guard.pid)` 停守护（否则 1s 内写回），再逐档 `echo N > /proc/touchpanel/sensitive_level` 对比；报点率 `sh tools/touch_rate.sh 5` 在 gs=0/1 两态各测一次（手指持续滑动才有数据）。用户观察报点≈2×显示刷新率（144 显示→≈288Hz）、540 仅 90Hz 显示档——重点验证 gs=1 是否解锁 2× 绑定，而不是追 540。
8. **导出体积**：doctor 导出只含 `tail -n 200` 日志；`tools/diag_pin.sh` 默认约 10–15KB，`PAD2PRO_DIAG_FULL=1` 才全文。
9. **探针回传**：`su -c sh <模块>/tools/probe_oplus.sh`，把 `/sdcard/Download/pad2pro_probe.txt` 发回（补齐 `/proc/touchpanel` 枚举、`touch_scene_default_para`、boost 节点证据）。
10. **卸载还原**：settings 四键回原值、档位回原档、user-preferred mode 清除；旧版升级用户 game_switch 回安装时值。
