# Pad 2 Pro 144Hz Fix & TouchTune (OPD2413)

一加 Pad 2 Pro 专用 KSU 模块：修复「卡在 120Hz 上不去 144」，全局锁 144Hz；附带触控优化。兼容 Magisk 目录布局。

## 它修的是什么（基于真机探针+实测）

| 现象 | 根因 |
|---|---|
| settings 三重锁写不进/被覆盖 | ❌ 实测排除：peak/min/user_mode 均写入成功，但仍 120 |
| **ColorOS 策略层压 render range** | ✅ 实锤：`mDisplayModeSpecs primary=physical:(0.0 144.0) render:(0.0 120.00001)` — 物理放行144、渲染帧率被 ColorOS 策略钉在 120 |
| **解法** | ✅ `service call SurfaceFlinger 1035 i32 6` 直切 SF 模式（T4 实测 `render=144Hz mActiveModeId=7`）→ 升级为主机制 + 看门狗每轮校验重打 |

面板档位（CSOT 3392x2400）：30/48/50/60/90/120/144，内核默认档就是 144（id 7）。

## 做了什么

**刷新率（v1.2：策略源头覆盖 + 三重锁 + 看门狗）**

0. **策略源头（v1.3.3 定稿：OverlayFS 路线）**：`/my_product/etc/refresh_rate_config.xml` 的 `maxrefreshsettings="3"`(=120，**设置状态会被截断**的总开关) 改 `4`(=144)。挂载交由 **Hybrid Mount 以 overlay 模式**自动合并模块内 `my_product/etc/refresh_rate_config.xml`（overlay 合并在 mountinfo 里不可见，属正常）；本模块 post-fs-data.sh 每次开机从当前原件刷新覆盖副本（OTA 自适应，sed 幂等），默认**不做手动 mount**；无元模块的环境可把 `POLICY_OVERLAY` 改 `1` 启用手动 bind 兜底（双视图+防重复+挂后验证，v1.2 实测有效）。原文件备份在 `/data/adb/p2p144/refresh_rate_config.xml.bak`
1. `peak_refresh_rate / min_refresh_rate` = 144.0（系统会改写为 120.00001，看门狗纠偏）
2. `oplus_customize_screen_refresh_rate=4`、`user_refresh_rate=144`（OPlus 侧保持一致）
3. `cmd display set-user-preferred-display-mode 2400 3392 144.0`（横竖屏参数自动兜底）
4. `service call SurfaceFlinger 1035 i32 <id>`：**T4 实测本机唯一运行时有效手段**（`render=144Hz mActiveModeId=7`），v1.1 起为主机制（`FORCE_SF_MODE=1`）
5. 看门狗：亮屏每 5s 巡检，settings 漂移或实测帧率≠144 即纠偏重打；灭屏放宽到 20s 省电；Plan B 生效后看门狗应无事可做（兜底）

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

KSU 管理器 → 模块 → 从存储安装 → 选 zip → 重启。

## 用法

- 看状态：KSU 模块卡片点「操作」按钮，或
  `sh /data/adb/modules/pad2pro_144_touch/apply.sh status`
- 立即应用：同目录 `apply.sh once`
- 调整行为：编辑模块目录下 `config.conf`（如想允许闲时降帧省电，把 `REFRESH_MIN` 改 `"10.0"`）

## 与挂载元模块（Hybrid Mount）配合

- 本机元模块为 Hybrid Mount（配置 `/data/adb/hybrid-mount/config.toml`，WebUI 在 KSU 管理器模块卡片）。HM 默认 overlay 模式合并模块文件（mountinfo 不可见）；想让本模块的策略覆盖以可见 bind 挂载，可在 HM 配置加：
  ```toml
  [rules.pad2pro_144_touch]
  default_mode = "magic"
  ```
- 无论 HM 怎么配，本模块 post-fs-data.sh 的手动 bind（双视图+防重复+挂后验证）都会执行，保证覆盖生效且可验证；两者叠加内容一致
- 诊断命令：`hybrid-mount api modules-list`（HM 对各模块的挂载模式）、`hybrid-mount api partitions`（受管分区列表，确认 my_product 是否被 HM 接管）

## 与其他模块共存

- **Extreme GT 4.2.2（Scene 工具箱安装的 Magisk 格式模块，去温控+锁帧）**：也会挂 `my_product/etc/refresh_rate_config.xml`，但实测它没改 `maxrefreshsettings`（装着它时文件仍是 3，卡 120 依旧）。本模块覆盖与其兼容（去温控走 thermal 文件，互不干扰）；同文件多层挂载时以最上层为准，若发现刷新率行为异常，用 check 脚本核对 `OVERLAY diff检查` 是否仍为 4

## 已知取舍

- 全局死锁 144（`min=144`）时，30fps 视频按 4/5/4/5 节奏播放可能有轻微抖动；介意就把 `REFRESH_MIN` 改 `"10.0"`（改为峰值锁，允许 AFR）
- 策略覆盖把所有 app 的「自动/高刷」档强制到 144：视频类 app 的智能降帧也失效（功耗略增）；想只放开上限不强制，把 `POLICY_OVERLAY` 改 `"0"`（退回看门狗方案）
- `ipePencilRateId="3"`（手写笔锁 120）刻意保留不动，避免手写笔管线异常
- 若某次大版本更新后系统又把 peak 写回 120：看门狗会在 5 秒内纠回来；Plan B 覆盖的是策略根源，正常情况下不再拉锯

## 接口交叉核对备注（来源：OnePlusOSS 内核源码 / LineageOS hardware_oplus）

- `game_switch_enable` 内核侧按**十六进制**解析（`kstrtoint(buf,16)`）：写 `1` = MODE_GAME 开；写非 0 时固件同时把 smooth/sensitive 置默认值、`major_rate_limit_times=0x0F`——这正是官方游戏触控行为，本模块写 `1` 与 HAL 兜底路径（无 framework_mode 时直写 "1"）完全一致
- `high_frame_rate <value> <time>` 子串协议需 `high_frame_rate_support=1`，本机探针为 0，不可用（故不写）
- SurfaceFlinger 1035 事务码在 OPlus Android 15/16 无可靠一手资料，但 T4 已在本机实测命中（mode id 6=144）
- Plan B 已在 v1.2 实现：bind-mount 覆盖 `/my_product/etc/refresh_rate_config.xml`（本机 rateId 词汇表 0=未指定 1=90 2=60 3=120 **4=144**，文件头部注释过时但尾部 `<config maxrefreshsettings="3">` 是 120 截断总开关），参考 github.com/barsikus007/OnePlus15-165HZ

## 验证方式

```
adb shell su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
adb shell su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望：`mActiveModeId=7`、`mActiveRenderFrameRate=144.00002`（或 144.x）。
