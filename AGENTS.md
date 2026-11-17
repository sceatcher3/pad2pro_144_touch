# AGENTS.md — pad2pro_144_touch

一加 Pad 2 Pro（OPD2413 / ColorOS 16）的 KernelSU / APatch / Magisk 模块：修「卡 120Hz 上不去 144」并保持 144（`peak=144` / `min=120`，保持可切换），附带触控优化。策略副本走标准模块目录、**由元模块合并生效，本模块不自挂载**；没接管时退化为纯运行时方案（min/peak + 看门狗）。触控由**独立守护**（`apply.sh guard`）维持档位（默认 2/3）与 `game_switch_enable=1`。
纯 `/system/bin/sh`，**没有构建步骤**，改文件即改产物。README.md 给用户看，本文件给改代码的 agent 看；分支细节与踩坑证据在 [docs/agent-notes.md](docs/agent-notes.md)，改哪块先读对应节。

## 验证（每次改 .sh 必做）

```sh
# 语法检查（PC 上 sh -n 即可）
for f in *.sh tools/*.sh tools/archive/*.sh; do sh -n "$f" || echo "FAIL $f"; done
```

真机（需 root；本机是 Android 平板，不在 PC 上跑）：

```sh
su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"
su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望 `mActiveModeId=7`、render≈`144.00002`、`refresh_changeable=true`、`peak=144.0`；`min`=120.0 或系统「智能切换」当前值（ksu 域写不进时关键看 `refresh_changeable=true`）。有外部接管时 `policy=maxrefreshsettings="4"` 且 `policy_complete=1`；无接管时 `policy_source=runtime-only` 且 render 仍 144（**退化不是故障**）。`refresh_changeable=false` 且 render=120 → 设置→显示与亮度→屏幕刷新率选「智能切换」。WebUI 与完整验收见 agent-notes.md §WebUI / §真机验收清单。

## 结构与执行顺序

| 文件 | 角色 | 何时跑 |
|---|---|---|
| `customize.sh` | 安装器：校验 `ro.product.model == OPD2413` 否则 `abort`；`set_perm 0755`；按 `POLICY_ENABLE` 生成/删除策略副本；输出只留结果行，不放 changelog | 安装时 |
| `post-fs-data.sh` | 从当前系统原件 `sed` 出策略副本到 `<模块>/my_product/etc/`（OTA 自适应、幂等）；`POLICY_ENABLE=0` 则移除副本；**不做任何挂载** | 开机早期 |
| `service.sh` | 清残留 `daemon.pid`/`guard.pid` → `sleep 10` 起 `apply.sh daemon`、`sleep 12` 起 `apply.sh guard`（两个独立进程） | late_start |
| `apply.sh` | 核心：备份、`setting_put`（三级回退+回读）、触控档位、退避看门狗、触控守护；子命令 `boot\|daemon\|guard\|once\|status` | 手动 / 守护 |
| `action.sh` | 模块卡「操作」按钮 → `apply.sh once` + `status` | 用户点按 |
| `uninstall.sh` | 杀守护、按 `backup.conf` 还原（含旧版 game_switch 行兼容）、清 user-preferred mode、umount 历史残留、删 `/data/adb/p2p144` | 卸载时 |
| `config.conf` | 全部可调开关（注释即文档），被 `apply.sh` / `post-fs-data.sh` 以 `.` 加载 | — |
| `webroot/index.html` | 只读 WebUI：两卡状态 + 日志大小/时间 + 一键导出到 `/sdcard/Download/`；不渲染日志内容 | 用户打开时 |
| `tools/*.sh` | 只读诊断，**不参与安装**、不被模块逻辑引用；`tools/archive/` 是一次性实验存档，不维护 | 排查时 |

## 通用约定（每个分支都守）

- **`MODDIR=${0%/*}`** 定位自身目录，不硬编码 `/data/adb/modules/...`（KSU/Magisk 布局、模块名都可能变）。
- **新配置项成对**：`config.conf` 一行 + `apply.sh` 里 `VAR=${VAR:-默认值}` 兜底一行，缺兜底会拿到空串。
- **版本号三处同步**：`module.prop` 的 `version`/`versionCode`（当前值以 `module.prop` 为准）+ 相关脚本头部注释；`versionCode` 必须递增。
- **幂等**：`post-fs-data.sh`/`apply.sh` 每次开机重复执行；写入前先比较当前值，或让 sed 正则对已处理过的文件仍成立。
- **守护单例（两个进程共用 `apply.sh` 入口，pidfile 分开）**：`alive()` 用 `daemon.pid` + `/proc/$p/cmdline` 含 `apply.sh` 且**不含 `guard`**；`guard_alive()` 用 `guard.pid` + cmdline 含 `guard`。改 `watch()`/`touch_guard()`/`service.sh` 时保留这些条件；触控守护保持独立进程，不塞进 `watch()`。
- **status 的 `key=value` 是接口**（`action.sh`/`tools/check_v12.sh` 依赖）：只加字段，不改已有键名；键清单以 `apply.sh` 的 status 分支为准。语义陷阱：`touch_switch`=持久档位优化是否启用（不是 game_switch）；`policy_bind` 恒为 no（历史兼容）。
- **settings 写入统一走 `setting_put`（三级回退 + 回读）**，失败只记日志、不假装成功；`min` 默认 `120.0` 不能 `144.0`（min=peak 会锁死 modeset，证据见 agent-notes.md §刷新率层）。漂移时重写 min/peak 触发 modeset，不盲打 SF 1035（本机实测空操作，默认关）。
- **看门狗保持「单职责 + 退避 + 限频」**，别往循环里塞别的巡检；节奏参数见 agent-notes.md §刷新率层。
- **写触控 proc 会持 `ts->mutex` ≥20ms**（报点线程同一把锁），守护写回用触摸 IRQ 计数差值避让报点活动（`fd_touch_count` 受 `face_detect_support` 门控本机不存在），连续避让 `TOUCH_GUARD_DEFER_MAX` tick 强制写一次。
- **运行日志只写 `/data/adb/p2p144/`**（`p2p.log`/`post_fs.log`/`backup.conf`），不写 `/sdcard`；用户导出与格式约定见 agent-notes.md §日志与导出。

## 分支细节（改哪块先读哪节）

| 触发 | 先读 |
|---|---|
| 改策略副本 / `post-fs-data.sh` / `customize.sh` / 挂载归因 | [agent-notes.md](docs/agent-notes.md) §策略层 |
| 改 settings 写入 / 看门狗 / SF 1035 | [agent-notes.md](docs/agent-notes.md) §刷新率层 |
| 改触控档位 / 守护 / game_switch / IRQ | [agent-notes.md](docs/agent-notes.md) §触控层 + [touch-research-v1.5.md](docs/touch-research-v1.5.md)（一手接口依据） |
| 动触控率 / 540Hz | 上一行 + [touch-rate-540-design.md](docs/touch-rate-540-design.md) |
| 改 `webroot/index.html` | [agent-notes.md](docs/agent-notes.md) §WebUI |
| 改日志 / 导出格式 | [agent-notes.md](docs/agent-notes.md) §日志与导出 |
| 真机验收 | [agent-notes.md](docs/agent-notes.md) §真机验收清单 |
| 守护 / 策略补全的设计推理与真机日志 | [v1.6-pin-design.md](docs/v1.6-pin-design.md) |
