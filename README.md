# Pad 2 Pro 144Hz Fix & TouchTune (OPD2413)

一加 Pad 2 Pro 专用模块（KSU / APatch / Magisk 均可）：修复「卡在 120Hz 上不去 144」，把上限放到 144Hz 并保持系统可切换；附带触控优化。策略覆盖副本走标准模块目录，由挂载元模块合并生效；本模块不自挂载（v1.5.0）。

## 它修的是什么（基于真机探针+实测）

| 现象 | 根因 |
|---|---|
| settings 三重锁写不进/被覆盖 | ❌ 实测排除：peak/min/user_mode 均写入成功，但仍 120 |
| **v1.5.2 实测：卡 120 后不再切** | ✅ `min_refresh_rate=144` 与 `peak=144` 相等 → `mRefreshRateChangeable=false`；ColorOS 认为刷新率固定，亮屏 resume 后停在 120 不再 modeset。切到「智能切换」后实测 `mActiveModeId=7`、render 144 |
| **解法** | ✅ 策略文件 `maxrefreshsettings=4` + `peak_refresh_rate=144` + `min_refresh_rate=120`（保持 `max-min>1`）；设置页选「智能切换」。`service call SurfaceFlinger 1035` 在本机实测为空操作，v1.5.2 起默认关闭 |

面板档位（CSOT 3392x2400）：30/48/50/60/90/120/144，内核默认档就是 144（id 7）。

## 做了什么（v1.5.2）

**刷新率：策略源头覆盖（元模块合并）+ peak=144/min=120 + 退避看门狗**

0. **策略源头**：`/my_product/etc/refresh_rate_config.xml` 的 `maxrefreshsettings="3"`(=120 截断总开关) 改 `4`(=144)，同时把 `rateId="a-b-c-d"` 两端改 `4`。覆盖副本生成到 `<模块>/my_product/etc/refresh_rate_config.xml`——标准模块目录布局，**由元模块合并生效**（overlay/magic/VFS 均可；overlay 合并在 mountinfo 不可见，属正常）。每次开机从当前系统原件重生成（OTA 自适应）。**本模块不再自己 bind**：没装元模块或元模块不接管 `my_product` 时，自动退化为纯运行时方案（下面 1-4 仍保 144，只是设置页的智能降帧等策略行为不变）。
1. **v1.5.2 关键修正**：`min_refresh_rate` 不再写 `144.0`，默认 `120.0`。本机实测 `min=peak=144` 会让 ColorOS 的 `mRefreshRateChangeable=false`，亮屏后停 120 不再 modeset；改成 120 后 `mRefreshRateChangeable=true`，系统可在 120/144 间切换并保持 144。设置页选「智能切换」是同一效果。
2. **SF 1035 仅保留实验开关**：`service call SurfaceFlinger 1035 i32 6` 在本机 ColorOS 16.0.10.600 上实测为空操作（返回 `Parcel(NULL)`、`debugDisplayModeByBackdoorPid` 始终 0、`i32 -1` 返回 Invalid argument）。v1.5.2 默认 `SF_1035_ENABLE=0`，不再作为运行期强制手段；只有其他 ROM/旧版本确认有效时才开。
3. **settings 写入**：`peak=144.0`、`min=120.0`、`oplus_customize_screen_refresh_rate=4`、`user_refresh_rate=144`、user-preferred display mode——开机/once 写一次。写入走 `setting_put`：`settings` → `runcon u:r:shell:s0 settings` → `content update` 三级回退 + 回读校验。本机 ksu 域直接 `settings put` 会 `Failed transaction`，模块会记日志而不是假装成功。
4. **看门狗（退避）**：亮屏稳态每 10s 查实测帧率；漂移时重写 min/peak 触发系统重新 modeset，2s 后复查；连续失败退避 10→20→40→60s 封顶，成功回稳态；同因日志每分钟最多一条；灭屏 20s 长睡。`SF_1035_ENABLE=1` 时才补 1035。

**触控（v1.5.0：持久档位，零拉锯）**

- **不再常驻写 `game_switch_enable`**。旧版每 5s 与 ColorOS 游戏助手互相重写形成拉锯；且一手内核源码证实本机写它只发一条固件 GAME_ON 命令（无 smooth/sensitive 副作用），v2 栈亮屏还会自动恢复——常驻维护既无必要又有害。详见 [docs/touch-research-v1.5.md](docs/touch-research-v1.5.md)。
- 改为开机/手动应用时写一次持久档位：`/proc/touchpanel/sensitive_level=4`、`smooth_level=1`（官方 DTS 档位表，chosen 档亮屏内核自动重放）。系统/游戏助手改档属官方意图，不对抗；充电插拔切厂商 charging 表，接受不补写。节点不存在（OTA 换栈）则跳过记日志，绝不盲写。
- 触控 IRQ 自动绑最强 CPU 簇（policy6, max 3.28GHz）：实测触控中断为 **IRQ 288（`touch-00`，GPIO 162）**，默认 378 万次中断全砸 CPU0 小核 → 改绑大核，匹配关键字就是 `touch`（不是 touchpanel）。
- 内核自带 `touch_boost_cpufreq`（触摸时 CPU 提频）保持原样不动。
- `/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` 格式未知，**只记录不盲写**。

**WebUI（v1.5.2：精简状态页 + 诊断导出）**：KSU/APatch 模块卡片直接打开 `webroot/index.html`，四张状态卡（看门狗/刷新率/策略/触控）2×2 一屏看完；「诊断与导出」区可一键导出日志或复制原始状态。页面**不渲染日志内容**、不展示 key=value 原文（复制按钮拿到的仍是完整 status 接口文本）；不写配置、不触发应用。策略卡结果导向：「已生效 / 运行时方案（中性）/ 未生效」；刷新率卡在 120 且 `refresh_changeable=false` 时会提示「固定刷新率模式 → 设置里选智能切换」；触控卡显示灵敏度/平滑档位。**日志每次重启自动清空**，只保留本次开机内容。

**安全设计**

- 首次运行自动备份原始值到 `/data/adb/p2p144/backup.conf`（settings 四键 + sensitive/smooth 档位；不再备份 game_switch）
- 卸载自动还原 + `cmd display clear-user-preferred-display-mode`；旧版备份的 game_switch 行兼容还原；历史版本自挂载残留 umount 兜底
- 安装时校验机型（非 OPD2413 拒装）
- 日志：`/data/adb/p2p144/p2p.log`、`post_fs.log`——**每次重启自动清空**（v1.5.1），只含本次开机内容；运行中超 100KB 仍会自动截断兜底

## 安装

KSU / APatch 管理器 → 模块 → 从存储安装 → 选 zip → 重启；Magisk 用「从本地安装」。

**前提（可选但推荐）**：装有接管 `my_product` 的挂载元模块（meta-overlayfs / Hybrid Mount / Magic Mount-rs 需 `extra_mount=["my_product"]` 等）。没有也能用——自动退化为纯运行时方案，仍保 144（peak=144/min=120）。

## 用法

- 看状态：KSU/APatch 模块卡片点「WebUI」，或点「操作」按钮，或
  `sh /data/adb/modules/pad2pro_144_touch/apply.sh status`
- 立即应用：同目录 `apply.sh once`
- 调整行为：编辑模块目录下 `config.conf`，改完重启或点「操作」（`POLICY_*` 必须重启）

| 键 | 默认 | 作用 |
|---|---|---|
| `REFRESH_PEAK` | `144.0` | `peak_refresh_rate`（开机/once 与漂移时写） |
| `REFRESH_MIN` | `120.0` | `min_refresh_rate`；必须保持 `peak-min>1` 才能让系统可切换。**不要用 144.0**（本机实测会固定刷新率、卡 120）；改 `10.0`＝允许闲时降帧省电 |
| `USER_REFRESH_RATE` | `144` | secure `user_refresh_rate` |
| `OPLUS_REFRESH_KEY` | `4` | secure `oplus_customize_screen_refresh_rate`（144 档=4） |
| `SF_FALLBACK_ID` | `6` | `SF_1035_ENABLE=1` 时解析不到目标 mode id 的兜底值 |
| `SF_1035_ENABLE` | `0` | `1`＝启用 SF 1035 实验强切；本机实测空操作，默认关闭 |
| `TOUCH_SENSITIVE_LEVEL` | `4` | `/proc/touchpanel/sensitive_level` 选档 0-5；`-1`＝不碰该节点 |
| `TOUCH_SMOOTH_LEVEL` | `1` | `/proc/touchpanel/smooth_level` 选档 0-5；`-1`＝不碰该节点 |
| `TOUCH_IRQ_AFFINITY` | `auto` | 触控 IRQ 绑最强 CPU 簇；`0` 关闭；也可写 `"6 7"` |
| `WATCH_INTERVAL` | `10` | 亮屏稳态巡检秒数（灭屏固定 20s；失败退避至 60s 封顶） |
| `TARGET_HZ` | `144` | 看门狗判定的目标实测帧率（也用于 SF mode id 解析） |
| `POLICY_ENABLE` | `1` | `1`＝生成策略覆盖副本；`0`＝不生成（纯运行时方案，改完重启） |
| `POLICY_RATE` | `4` | 策略文件 rateId/maxrefreshsettings 目标档（4=144） |

v1.5.0 移除的键：`POLICY_MOUNT`（不再自挂载）、`FORCE_SF_MODE`（SF 不再是主机制，改用 `SF_1035_ENABLE` 实验开关）、`FORCE_USER_MODE`（user-mode 随 boot 无条件写）、`TOUCH_GAME_SWITCH`（改持久档位方案）。旧 config 里残留这些键无害，会被忽略。

## WebUI（KernelSU / APatch）

安装/更新后**重启一次**，模块卡片会出现 **WebUI** 入口（`webroot/index.html`，管理器用 WebView 打开，不需要端口或额外服务）。重启后守护进程约 10 秒启动，状态页点「刷新」即可。

![WebUI 状态页（v1.4.3 旧版预览，v1.5.2 已精简为四卡 2×2 + 诊断导出区）](docs/webui-preview.png)

- **状态页（v1.5.2）**：四卡 2×2 网格（窄屏单列），一屏看完——看门狗、实测刷新率、策略覆盖（已生效 / 运行时方案 / 未生效）、触控档位（灵敏度/平滑）。每 10 秒静默自动刷新，顶栏显示更新时间。刷新率卡在固定模式且卡 120 时会提示去设置里选「智能切换」。
- **诊断与导出**：「导出日志」把状态、策略、两份日志（本次开机起）与挂载信息合成一个 txt 写到 `/sdcard/Download/pad2pro-doctor-<时间>.txt`；「复制状态」把完整 `key=value` 原始接口文本放进剪贴板（页面本身不展示原文）。导出在设备侧完成；Download 不可写时自动回退 `/data/local/tmp/`，toast 报出实际路径。日志大小/时间参考行可判断守护是否在写。
- **反馈**：每个按钮点击都有 toast；自动刷新不打扰。
- **只读**：不改 `config.conf`、不触发 `apply.sh once`；要立即应用仍点模块卡「操作」按钮。
- 普通浏览器打开只会显示提示页；Magisk 原生没有模块 WebUI，继续用「操作」按钮或命令行。

## 挂载与元模块

**什么是元模块（metamodule）**：KernelSU 把「模块如何被挂载」委托给一种特殊模块——`module.prop` 带 `metamodule=1`，如 meta-overlayfs、Hybrid Mount、Magic Mount-rs、Mountify。同一时间只能装一个；**没装元模块，所有普通模块都不会被挂载**（[KSU 官方文档](https://kernelsu.org/guide/metamodule.md)）。它在开机时扫描所有模块的分区目录（含本模块的 `my_product/etc/`）合并进系统。

- 覆盖文件写在模块自己的 `my_product/etc/` 下，标准模块目录布局，任何支持分区目录的元模块都能识别；无需为某个元模块写规则或改它的配置。
- **本模块不自挂载（v1.5.0）**。有些元模块默认不接管 `my_product`（如 Magic Mount-rs 要 `extra_mount=["my_product"]`）——去配它，或接受退化：`policy_source=runtime-only` 表示策略覆盖未生效，peak/min + 看门狗仍在保 144，WebUI 显示中性「运行时方案」而非异常。
- **其他模块可能盖住本模块副本**：例如 extreme_gt（解锁帧率/温控的普通模块）会自己 bind 同一策略文件叠在最上层。这属正常竞争——本模块只看活文件结果（`policy=maxrefreshsettings="4"` 即达标），不区分来源、不对抗。
- 核对：`policy=` 应为 `maxrefreshsettings="4"`。`policy_bind` 键保留兼容但 v1.5.0 起恒为 `no`（历史残留除外）。
- `policy_module`（覆盖副本自身内容）用于排查：副本=4 而 policy=3 = 没有外部接管；两个都是 3 = 副本没生成对（看 `post_fs.log`）。
- 关掉 `POLICY_ENABLE` 时，若元模块在本次开机早期已经合并了旧副本，那个副本可能撑完这一轮开机；稳妥做法是重启两次，或先手动删掉模块下的 `my_product/` 再重启。

## tools/ 诊断脚本（不参与安装，仅排查用）

- `check_v12.sh`：一键体检（144Hz 状态/策略 diff/挂载归因），输出 `/sdcard/Download/p2p_v12_check.txt`
- `probe_oplus.sh`：只读探针（显示/触控接口枚举，v1.5.0 补采 `touch_scene_default_para` 与 boost 节点全文、touchHidlTest 存在性），输出 `/sdcard/Download/pad2pro_probe.txt`
- `archive/tune_144.sh`：T1–T5 一次性实验存档（会改系统设置，末尾还原），结论已并入 `apply.sh`，平时不用跑

## 已知取舍

- v1.5.2 起默认 `min=120`，保留高刷下限并让系统可切 144；`min=144` 会让 ColorOS 进入固定刷新率，本机实测亮屏后卡 120，**不要用**。30fps 视频若抖动，可把 `REFRESH_MIN` 改 `"10.0"`（允许更低 AFR）
- 设置页的「高刷新率」可能把 min/peak 都写成 144，导致同样的固定模式；遇到卡 120 请选「智能切换」。WebUI 刷新率卡会显示「固定刷新率模式」提示
- 本机 ksu 域直接 `settings`/`cmd`/`input` 会被 system_server 拒绝（Failed transaction），`su 2000` 仍是 ksu 域；模块已加 `content` 回退 + 回读，回退也失败会记日志。真机改设置仍以系统设置页为准
- `SF_1035_ENABLE=1` 仅供其他 ROM/旧版本实验；本机已实测为空操作，不要依赖
- 策略覆盖把所有 app 的「自动/高刷」档强制到 144：视频类 app 的智能降帧也失效（功耗略增）；想只放开上限不强制，把 `POLICY_ENABLE` 改 `"0"`（改完重启）
- 其他模块若也挂同一策略文件，多层以最上层为准；刷新率行为异常时用 `tools/check_v12.sh` 核对 `OVERLAY diff检查` 是否仍为 4
- `ipePencilRateId="3"`（手写笔锁 120）刻意保留不动，避免手写笔管线异常；触控档位的 `pen_sensitive_level` 场景键同样不碰
- 触控档位方向（数值越小越灵敏）来自 DTS 推断，固件语义闭源；真机手感不对就改 `TOUCH_SENSITIVE_LEVEL`/`TOUCH_SMOOTH_LEVEL`（0=厂商默认，-1=不碰），不用改代码
- 充电插拔会把 sensitive 切到厂商 charging 表（同档略保守），本模块接受不补写
- 游戏助手进游戏时可能把档位改回它自己的值——属官方意图，本模块不对抗（这正是「零拉锯」的含义）
- WebUI 刻意只读：改配置仍编辑 `config.conf`，避免网页把引号/注释改坏

## 接口交叉核对备注（来源：OnePlusOSS 内核源码 / LineageOS hardware_oplus）

- **v1.5.0 修正**：本机（NT36536 / v2 栈 / erhai DTS）写 `game_switch_enable` 非 0 **不会**动 smooth/sensitive、也无 major_rate_limit 副作用（DTS 无对应 support）；唯一效果是固件 GAME_ON 命令。v2 栈灭屏清固件但不清状态，**亮屏自动恢复**游戏模式与档位——旧版「看门狗防灭屏丢失」的假设不成立。详见 [docs/touch-research-v1.5.md](docs/touch-research-v1.5.md)。
- `game_switch_enable` 内核侧按十六进制解析（`kstrtoint(buf,16)`），common 层只做 `value>0` 布尔判断；社区 node 26 魔法值档位表属闭源 touchDaemon framework_mode 路径，本机无该节点，不适用
- `high_frame_rate` 子串协议需 `high_frame_rate_support=1`，本机为 0；`report_rate*` 节点本机 DTS 无 support——报点率由固件按显示刷新率自适应，用户态无旋钮
- **v1.5.2 修正**：SurfaceFlinger 1035 在本机实测为空操作（`service call ... i32 6` 返回 `Parcel(NULL)`、`debugDisplayModeByBackdoorPid` 始终 0、`i32 -1` 返回 Invalid argument）；之前看到的 144 来自默认模式/系统自身切换，不是 1035 的功劳。默认 `SF_1035_ENABLE=0`
- **v1.5.2 修正**：`min_refresh_rate=peak_refresh_rate=144` 会让 `DisplayModeDirector.mRefreshRateChangeable=false`；ColorOS 亮屏 resume 后停 120 不再 modeset。切「智能切换」（或 min=120）后实测 `mActiveModeId=7`。AOSP 判据：`max-min > 1 && max > 60` 才 changeable
- 策略源头覆盖演进：v1.2 手动 bind → v1.3.3 只交元模块 → v1.3.5 标准目录+bind 兜底 → v1.4.1 修 sed `/g` → v1.4.2 bind 判据看活文件 → **v1.5.0 删除全部自挂载，只留元模块合并 + 运行时退化**。rateId 词汇表 0=未指定 1=90 2=60 3=120 **4=144**；文件头部注释过时，尾部 `<config maxrefreshsettings="3">` 才是 120 截断总开关。参考 github.com/barsikus007/OnePlus15-165HZ

## 验证方式

```
adb shell su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
adb shell su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望：`mActiveModeId=7`、`mActiveRenderFrameRate=144.00002`（或 144.x）、`refresh_changeable=true`、`peak=144.0`；`min` 为 `120.0`（写入成功时）或系统「智能切换」的当前值（ksu 域写不进去时，不影响 144，只要 `refresh_changeable=true`）。有元模块时 `policy=maxrefreshsettings="4"`、`policy_source=meta`；无元模块时 `policy_source=runtime-only` 且 render 仍 144。若 `refresh_changeable=false` 且 render=120，去设置→显示与亮度→屏幕刷新率选「智能切换」。

WebUI：模块卡 → WebUI → 状态页应显示「正常」（无元模块时策略卡为中性「运行时方案」，总体仍可「正常」）；点「导出日志」应在 `/sdcard/Download/` 出现 `pad2pro-doctor-<时间>.txt`。

### v1.5.2 真机验收清单

1. **有元模块**：重启 → status `policy=4`、`policy_source=meta`、`render=144Hz`、`daemon=alive`；WebUI 总体「正常」。
2. **无元模块（模拟：临时禁用元模块重启）**：`policy_source=runtime-only`、`render=144Hz`；WebUI 策略卡中性「运行时方案」，不标红。验完恢复元模块。
3. **看门狗/固定模式**：亮屏静置 10 分钟，`p2p.log` 不应刷屏（稳态无日志）；把设置页切到「高刷新率」或手动把 min 改成 144 制造固定模式，观察 ≤10s 内重写设置、2s 复查；仍不达标时退避间隔递增且日志每分钟 ≤1 条。切回「智能切换」应恢复 144。
4. **灭亮屏**：灭屏 1 分钟再亮屏，render 仍 144；`cat /proc/touchpanel/sensitive_level /proc/touchpanel/smooth_level` 档位保持（内核自恢复）。
5. **充电插拔**：插/拔充电器后回读档位——sensitive 可能切到 charging 表值（预期行为，不补写）；render 不受影响。
6. **游戏进出**：进游戏再退出，回读档位与 `game_switch_enable`——系统可能改档/清 gs，本模块不反写（零拉锯）；`p2p.log` 无触控重写记录。
7. **A/B 手感**：`TOUCH_SENSITIVE_LEVEL` 分别设 0（厂商默认）与 4/5 对比跟手性；方向反了改配置默认值。
8. **探针回传**：`su -c sh <模块>/tools/probe_oplus.sh`，把 `/sdcard/Download/pad2pro_probe.txt` 发回（补齐 `/proc/touchpanel` 枚举、`touch_scene_default_para`、boost 节点全文证据）。
9. **卸载还原**：卸载后 settings 四键回原值、档位回原档、user-preferred mode 清除；旧版升级用户 game_switch 也回安装时值。

## 改代码

要动脚本/配置先读 [AGENTS.md](AGENTS.md)：脚本执行顺序、必守约定（`MODDIR`、配置兜底、版本号同步、幂等、守护单例）和踩过的坑都在那；本文件只讲「为什么这么修」和对用户的手动操作。触控接口的一手源码依据见 [docs/touch-research-v1.5.md](docs/touch-research-v1.5.md)。