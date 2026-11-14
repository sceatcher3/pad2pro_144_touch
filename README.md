# Pad 2 Pro 144Hz Fix & TouchTune (OPD2413)

一加 Pad 2 Pro 专用模块（KSU / APatch / Magisk 均可）：修复「卡在 120Hz 上不去 144」，全局锁 144Hz；附带触控优化。挂载走标准模块目录，适配任意挂载元模块。

## 它修的是什么（基于真机探针+实测）

| 现象 | 根因 |
|---|---|
| settings 三重锁写不进/被覆盖 | ❌ 实测排除：peak/min/user_mode 均写入成功，但仍 120 |
| **ColorOS 策略层压 render range** | ✅ 实锤：`mDisplayModeSpecs primary=physical:(0.0 144.0) render:(0.0 120.00001)` — 物理放行144、渲染帧率被 ColorOS 策略钉在 120 |
| **解法** | ✅ `service call SurfaceFlinger 1035 i32 6` 直切 SF 模式（T4 实测 `render=144Hz mActiveModeId=7`；SF 侧 id 6 对应 display 侧 mode 7，运行期由脚本动态解析）→ 升级为主机制 + 看门狗每轮校验重打 |

面板档位（CSOT 3392x2400）：30/48/50/60/90/120/144，内核默认档就是 144（id 7）。

## 做了什么

**WebUI（v1.4.3：单页状态 + 一键导出日志）**：KSU/APatch 模块卡片直接打开 `webroot/index.html`，看守护/刷新率/策略/触控状态与两个日志文件的字节数/最后写入时间；点「导出日志」把状态、策略、两份日志与挂载信息合成一个 txt 写到 `/sdcard/Download/`。页面**不渲染日志内容**（旧版的日志页在真机上被桥的输出长度上限截断，已移除）；不写配置、不触发应用。

**刷新率（v1.3.5：策略源头覆盖 + 三重锁 + 看门狗）**

0. **策略源头（v1.3.5：标准模块目录 + 自检兜底）**：`/my_product/etc/refresh_rate_config.xml` 的 `maxrefreshsettings="3"`(=120，**设置状态会被截断**的总开关) 改 `4`(=144)，同时把 `rateId="a-b-c-d"` 两端改 `4`。覆盖副本生成到 `<模块>/my_product/etc/refresh_rate_config.xml`——标准模块目录布局，元模块接管 `my_product` 时直接合并（overlay 合并在 mountinfo 不可见，属正常）；没接管或没装元模块时，`post-fs-data.sh` 开机自检活文件，不是 4 就自己 bind 兜底（`POLICY_MOUNT=auto`，默认）。不调用任何元模块的 CLI、不读它的私有配置。（v1.4.1 修：策略文件是单行 XML，头部注释里也有一个 `maxrefreshsettings`，替换必须带 `/g`；漏了只会改到注释，尾部总开关仍是 3，表现为「自挂载=yes 但策略未生效」。v1.4.2：bind 判据改成看活文件内容，`service.sh` 在 late_start 再补跑一次，兜住「元模块后叠加把 bind 盖住」。）
1. `peak_refresh_rate / min_refresh_rate` = 144.0（系统会改写为 120.00001，看门狗纠偏）
2. `oplus_customize_screen_refresh_rate=4`、`user_refresh_rate=144`（OPlus 侧保持一致）
3. `cmd display set-user-preferred-display-mode 2400 3392 144.0`（横竖屏参数自动兜底）
4. `service call SurfaceFlinger 1035 i32 <id>`：**T4 实测本机唯一运行时有效手段**（`render=144Hz mActiveModeId=7`），v1.1 起为主机制（`FORCE_SF_MODE=1`）
5. 看门狗：亮屏每 5s 巡检，settings 漂移或实测帧率≠144 即纠偏重打；灭屏放宽到 20s 省电；策略覆盖生效后看门狗应无事可做（兜底）

**触控**
- `/proc/touchpanel/game_switch_enable=1`：官方游戏触控通道（本机无 framework_mode，HAL 兜底走的就是它）
- 触控 IRQ 自动绑最强 CPU 簇（policy6, max 3.28GHz）：实测触控中断为 **IRQ 288（`touch-00`，GPIO 162）**，默认 378 万次中断全砸 CPU0 小核 → 改绑大核，匹配关键字就是 `touch`（不是 touchpanel）
- 内核自带 `touch_boost_cpufreq`（触摸时 CPU 提频）保持原样不动
- `/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` 格式未知，**只记录不盲写**

**安全设计**
- 首次运行自动备份原始值到 `/data/adb/p2p144/backup.conf`
- 卸载自动还原 + `cmd display clear-user-preferred-display-mode`
- 安装时校验机型（非 OPD2413 拒装）
- 日志：`/data/adb/p2p144/p2p.log`（超 100KB 自动截断）

## 安装

KSU / APatch 管理器 → 模块 → 从存储安装 → 选 zip → 重启；Magisk 用「从本地安装」。

## 用法

- 看状态：KSU/APatch 模块卡片点「WebUI」，或点「操作」按钮，或
  `sh /data/adb/modules/pad2pro_144_touch/apply.sh status`
- 立即应用：同目录 `apply.sh once`
- 调整行为：编辑模块目录下 `config.conf`，改完重启或点「操作」（`config.conf` 才是唯一配置源，下表与它一一对应；`POLICY_*` 必须重启）

| 键 | 默认 | 作用 |
|---|---|---|
| `REFRESH_PEAK` | `144.0` | `peak_refresh_rate` |
| `REFRESH_MIN` | `144.0` | `min_refresh_rate`；改 `10.0`＝只锁峰值、允许闲时降帧省电 |
| `USER_REFRESH_RATE` | `144` | secure `user_refresh_rate` |
| `OPLUS_REFRESH_KEY` | `4` | secure `oplus_customize_screen_refresh_rate`（144 档=4） |
| `FORCE_USER_MODE` | `1` | 是否写 user-preferred display mode（辅助手段） |
| `FORCE_SF_MODE` | `1` | 是否 `service call SurfaceFlinger 1035` 强切（主机制） |
| `SF_FALLBACK_ID` | `6` | 解析不到 144 mode id 时的兜底值 |
| `TOUCH_GAME_SWITCH` | `1` | 写 `/proc/touchpanel/game_switch_enable` |
| `TOUCH_IRQ_AFFINITY` | `auto` | 触控 IRQ 绑最强 CPU 簇；`0` 关闭；也可写 `"6 7"` |
| `WATCH_INTERVAL` | `5` | 亮屏巡检秒数（灭屏固定 20s） |
| `TARGET_HZ` | `144` | 看门狗判定的目标实测帧率 |
| `POLICY_ENABLE` | `1` | `1`＝生成策略覆盖副本；`0`＝不生成（纯看门狗方案，改完重启） |
| `POLICY_MOUNT` | `auto` | `auto`＝开机自检没生效才 bind；`always`＝无条件 bind；`never`＝只交给元模块（改完重启） |
| `POLICY_RATE` | `4` | 策略文件 rateId/maxrefreshsettings 目标档（4=144） |

## WebUI（KernelSU / APatch）

安装/更新后**重启一次**，模块卡片会出现 **WebUI** 入口（`webroot/index.html`，管理器用 WebView 打开，不需要端口或额外服务）。重启后守护进程约 10 秒启动，状态页点「刷新」即可。

![WebUI 状态页（假数据渲染，点「导出日志」后的 toast）](docs/webui-preview.png)

- **状态页**：看门狗是否在跑、实测/目标刷新率、策略 `maxrefreshsettings` 与自挂载、触控通道；原始 `key=value` 可一键复制。
- **日志**：状态页只看两个日志文件的大小与最后写入时间（判断守护有没有在写日志）；要看内容点「导出日志」，文件落 `/sdcard/Download/pad2pro-doctor-<时间>.txt`，含 `apply.sh status`、策略活文件/副本、`p2p.log`、`post_fs.log`、`refresh_rate` 挂载信息，可直接发回分析。导出在设备侧完成，不受页面渲染限制；`/sdcard/Download/` 不可写时自动回退 `/data/local/tmp/`，toast 会报出实际路径。
- **反馈**：每个按钮点击都有 toast 提示（动作 + 结果）；自动刷新不打扰。
- **只读**：不改 `config.conf`、不触发 `apply.sh once`；要立即应用仍点模块卡「操作」按钮。
- 普通浏览器打开只会显示提示页；Magisk 原生没有模块 WebUI，继续用「操作」按钮或命令行。

## 挂载与元模块（自动适配）

- 覆盖文件写在模块自己的 `my_product/etc/` 下，这是标准模块目录布局，任何支持分区目录的挂载元模块都能识别；无需为某个元模块写规则或改它的配置。
- 有些元模块默认不接管 `my_product`。不用去配它——`POLICY_MOUNT=auto`（默认）会在开机时读一次活文件，`maxrefreshsettings` 还不是 `4` 就自己 bind 到 `/my_product/etc/refresh_rate_config.xml` 与 `/mnt/vendor/my_product/etc/refresh_rate_config.xml`（后者存在才挂、防重复）；元模块稍后叠加上来内容也一致。
- 想强制自己挂：`POLICY_MOUNT="always"`；完全信任元模块：`"never"`。
- v1.4.2 起，开机早期挂一次、late_start 再核对一次（`service.sh` 补跑 `post-fs-data.sh`）：元模块如果在后面才叠加 `/my_product`，第二次会把自己的 bind 补在最上层，活文件仍是 4。
- 核对：`apply.sh status` 的 `policy=` 应为 `maxrefreshsettings="4"`。`policy_bind=no` 不代表没生效（overlay 合并在 mountinfo 不可见），以 `policy=` 为准。
- 状态页显示「未生效」时看原始状态里的 `policy_module`（覆盖副本自身的内容）：`policy_module=maxrefreshsettings="4"` 而 `policy` 还是 3 = 副本对但没盖住活文件（看 `policy_bind` 与 `post_fs.log` 的 `bind ... rc=`）；两个都是 3 = 副本没生成对（`post_fs.log` 会写「覆盖副本尾部 ... != maxrefreshsettings="4"」）。
- 关掉 `POLICY_ENABLE` 时，若元模块在本次开机早期已经合并了旧副本，那个副本可能撑完这一轮开机；稳妥做法是重启两次，或先手动删掉模块下的 `my_product/` 再重启。

## tools/ 诊断脚本（不参与安装，仅排查用）

- `check_v12.sh`：一键体检（144Hz 状态/策略 diff/挂载归因），按脚本自身位置定位模块目录，输出 `/sdcard/Download/p2p_v12_check.txt`
- `probe_oplus.sh`：只读探针（显示/触控接口枚举），输出 `/sdcard/Download/pad2pro_probe.txt`
- `archive/tune_144.sh`：T1–T5 一次性实验存档（会改系统设置，末尾还原），结论已并入 `apply.sh`，平时不用跑

v1.4.3 清理：删掉 `mnt_debug.sh`（内容与 `check_v12.sh` 的 MOUNTINFO 段重复）、`probe2.sh`（与 `probe_oplus.sh` 重叠且输出顺序有 bug），`tune_144.sh` 移入 `tools/archive/`。

## 已知取舍

- 全局死锁 144（`min=144`）时，30fps 视频按 4/5/4/5 节奏播放可能有轻微抖动；介意就把 `REFRESH_MIN` 改 `"10.0"`（改为峰值锁，允许 AFR）
- 策略覆盖把所有 app 的「自动/高刷」档强制到 144：视频类 app 的智能降帧也失效（功耗略增）；想只放开上限不强制，把 `POLICY_ENABLE` 改 `"0"`（不生成覆盖副本，退回纯看门狗方案；改完重启）
- 其他模块若也挂同一策略文件，多层以最上层为准；刷新率行为异常时用 `tools/check_v12.sh` 核对 `OVERLAY diff检查` 是否仍为 4
- `ipePencilRateId="3"`（手写笔锁 120）刻意保留不动，避免手写笔管线异常
- 若某次大版本更新后系统又把 peak 写回 120：看门狗会在 5 秒内纠回来；策略覆盖动的是根源，正常情况下不再拉锯
- WebUI 刻意只读：改配置仍编辑 `config.conf`，页面不会写配置，避免网页把引号/注释改坏

## 接口交叉核对备注（来源：OnePlusOSS 内核源码 / LineageOS hardware_oplus）

- `game_switch_enable` 内核侧按**十六进制**解析（`kstrtoint(buf,16)`）：写 `1` = MODE_GAME 开；写非 0 时固件同时把 smooth/sensitive 置默认值、`major_rate_limit_times=0x0F`——这正是官方游戏触控行为，本模块写 `1` 与 HAL 兜底路径（无 framework_mode 时直写 "1"）完全一致
- `high_frame_rate <value> <time>` 子串协议需 `high_frame_rate_support=1`，本机探针为 0，不可用（故不写）
- SurfaceFlinger 1035 事务码在 OPlus Android 15/16 无可靠一手资料，但 T4 已在本机实测命中（`1035 i32 6` → `mActiveModeId=7`）
- 策略源头覆盖：v1.2 手动 bind → v1.3.3 只交元模块 overlay → v1.3.5 标准模块目录 + 开机自检兜底（`POLICY_MOUNT=auto/always/never`，`POLICY_ENABLE=0` 可整体关闭）→ v1.4.1 修 sed 漏 `/g`（单行 XML 只改到头部注释）→ v1.4.2 bind 判据改看活文件 + late_start 复核 → v1.4.3 WebUI 收敛为单页状态 + 日志导出（日志页移除，导出改设备侧合成）、`tools/` 清理。rateId 词汇表 0=未指定 1=90 2=60 3=120 **4=144**；文件头部注释过时，尾部 `<config maxrefreshsettings="3">` 才是 120 截断总开关。参考 github.com/barsikus007/OnePlus15-165HZ

## 验证方式

```
adb shell su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
adb shell su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望：`mActiveModeId=7`、`mActiveRenderFrameRate=144.00002`（或 144.x）、`policy=maxrefreshsettings="4"`。

WebUI：模块卡 → WebUI → 状态页应显示「正常」；点「导出日志」应在 `/sdcard/Download/` 出现 `pad2pro-doctor-<时间>.txt`，文件里 `===== STATUS =====` 段与命令行 status 一致。

## 改代码

要动脚本/配置先读 [AGENTS.md](AGENTS.md)：脚本执行顺序、必守约定（`MODDIR`、配置兜底、版本号同步、幂等、守护单例）和踩过的坑都在那；本文件只讲「为什么这么修」和对用户的手动操作。
