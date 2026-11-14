# AGENTS.md — pad2pro_144_touch

一加 Pad 2 Pro（OPD2413 / ColorOS 16）的 KernelSU / APatch / Magisk 模块：把「卡 120Hz 上不去 144」修好并锁 144，附带触控优化。挂载走标准模块目录 + 开机自检兜底，不绑定任何具体元模块。
纯 `/system/bin/sh`，**没有构建步骤**，改文件即改产物；README.md 是给用户看的说明，本文件是给改代码的 agent 看的约定。

## 验证方式（唯一可用手段）

本机是 Android 平板，不在 PC 上跑：

```sh
# 语法检查（每次改 .sh 都做，PC 上 sh -n 即可）
for f in *.sh tools/*.sh; do sh -n "$f" || echo "FAIL $f"; done

# 真机（需 root）
su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"   # policy= 应为 maxrefreshsettings="4"
su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望 `mActiveModeId=7`（144 档）、`mActiveRenderFrameRate=144.00002` 左右。

WebUI（真机）：模块卡 → WebUI → 状态页应显示「正常」；日志页可切换/复制/保存。页面无 bridge 时只显示提示页，属正常。

## 结构与执行顺序

| 文件 | 角色 | 何时跑 |
|---|---|---|
| `customize.sh` | 安装器：校验机型 `ro.product.model == OPD2413`，否则 `abort`；给脚本 `set_perm 0755`；`POLICY_ENABLE=1` 时现场生成 `my_product/etc/refresh_rate_config.xml`（=0 则删掉） | 安装时 |
| `post-fs-data.sh` | 从当前系统原件 `sed` 出覆盖副本到 `<模块>/my_product/etc/`（OTA 自适应、幂等）；`POLICY_ENABLE=0` 则移除副本；再按 `POLICY_MOUNT=auto/always/never` 决定是否自检并 bind 兜底 | 每次开机早期 |
| `service.sh` | 清残留 `daemon.pid` → `sleep 10` → **补跑一次 `post-fs-data.sh`**（兜住晚叠加的元模块）→ 后台起 `apply.sh daemon` | 开机 late_start |
| `apply.sh` | 核心：备份、三重锁、SF 强切、触控、看门狗循环；子命令 `boot\|daemon\|once\|status` | 手动 / 守护 |
| `action.sh` | KSU 模块卡「操作」按钮 → `apply.sh once` + `status` | 用户点按 |
| `uninstall.sh` | 杀守护进程、按 `backup.conf` 还原、清 user-preferred mode、摘挂载、删 `/data/adb/p2p144` | 卸载时 |
| `config.conf` | 全部可调开关，被 `apply.sh` / `post-fs-data.sh` 以 `.` 加载 | — |
| `webroot/index.html` | 模块 WebUI：只读状态/日志/复制/保存；KSU/APatch 管理器用 WebView 打开 | 用户打开时 |
| `tools/*.sh` | 只读/实验诊断脚本，**不参与安装**，不要被模块逻辑引用 | 排查时 |

## 改代码时守住的约定

- **`MODDIR=${0%/*}`**：所有脚本用这一行定位自身目录，不要硬编码 `/data/adb/modules/...`（KSU 与 Magisk 布局、模块名都可能变）。
- **新增配置项要成对**：`config.conf` 加一行 + `apply.sh` 里 `VAR=${VAR:-默认值}` 兜底一行。缺兜底会在用户配置缺失时拿到空串。
- **写 settings 不是一劳永逸**：ColorOS 会把 `peak_refresh_rate` 改写成 `120.00001`。所以「写入」和「看门狗纠偏」是同一件事的两半，改写入逻辑要顺手看 `watch()` 的漂移判断（按整数部分比较，`PEAK_I`/`MIN_I`）。
- **版本号三处同步**：`module.prop` 的 `version` / `versionCode` + 相关脚本头部注释里的版本说明。`versionCode` 必须递增。当前 1.4.2 / versionCode 11。
- **幂等**：`post-fs-data.sh` 与 `apply.sh` 都可能在每次开机重复执行。写入前先比较当前值（如 `gs_state`），或让 sed 正则对已处理过的文件仍成立。
- **守护进程单例**：`alive()` 用 `PIDF` + `/proc/$p/cmdline` 含 `apply.sh` 双条件判断，避免重启后 PID 复用误判。改 `watch()`/`service.sh` 时保留这两条。
- **status 输出是接口**：`action.sh` 和 `tools/check_v12.sh` 都依赖 `apply.sh status` 的 `key=value` 行。加字段可以，别改已有键名。v1.4.0 新增 `daemon`、`target_hz`、`policy_enable`、`touch_switch`、`module_disabled`，WebUI 依赖它们；v1.4.1 追加 `policy_module`（覆盖副本自身的内容）。

## WebUI 约定（v1.4.0）

- **只读**：`webroot/index.html` 不写 `config.conf`、不触发 `apply.sh once`、不改系统设置；只读 status/日志、复制、写 `/sdcard/Download/DSH-Go/` 导出。
- **零依赖**：单文件、内联 CSS/JS、无 CDN/外部字体/图标；只做深色模式。
- **命令写死**：所有 `exec` 命令由页面常量拼接，只有模块目录经 `shq()` 加引号；不接受页面输入拼 shell。
- **渲染安全**：状态/日志一律 `textContent`，禁止把文件内容塞进 `innerHTML`。
- **模块目录**：不写死路径；先按 `module.prop` 的 `id` 扫 `/data/adb/modules/*`，回退 `/data/adb/modules/pad2pro_144_touch`。
- **桥差异**：KSU `exec` 返回 `{errno,stdout,stderr}`，APatch 返回字符串；页面适配层统一，并在命令末尾追加 `__RC=$?` 取真实退出码。不要依赖 `ksu.spawn`。
- **权限**：`webroot` 的权限/SELinux 由管理器设置，不要在 `customize.sh` 里 chmod。
- **验收**：开发环境没有 `/data/adb`，真机最终以模块卡 WebUI 打开为准；改完先跑 `sh -n` 和页面 JS 语法检查。

## 已知坑（踩过的）

- **SF 事务码 `service call SurfaceFlinger 1035 i32 <id>`** 是运行期唯一实测有效的手段；id 从 `dumpsys SurfaceFlinger` 里抓 `vsyncRate=144.00` 那条，抓不到才用 `SF_FALLBACK_ID`。别再退回「只写 settings」。
- **`id 6` 与 `mActiveModeId=7` 不是同一个编号空间**：`1035 i32 6` 是 SF 侧 mode id（T4 实测有效），切完后 `dumpsys display` 看到的是 `mActiveModeId=7`（display 侧 144 档）。`apply.sh` 动态抓 SF 侧 id，抓不到才用 `SF_FALLBACK_ID=6`；别把两个数字当成互相矛盾。
- **元模块的挂载方式不统一**：overlay（mountinfo 不可见）、magic mount/bind（可见）、VFS/nomount（没有真实挂载）都存在；有些元模块默认不接管 `my_product`（例如 Magic Mount-rs 要 `extra_mount=["my_product"]`，meta-overlayfs / Hybrid Mount 按分区目录合并）。所以判断生效只看活文件内容 `maxrefreshsettings`，不看 `mount` 输出、不依赖任何元模块 CLI。
- **`POLICY_MOUNT` 兜底语义**：`auto` 只在活文件不是目标值时 bind；`always` 无条件 bind 但先查 mountinfo 防重复；`never` 完全不碰挂载。bind 两个视图（`/my_product`、`/mnt/vendor/my_product`，后者存在才挂）。改这套逻辑时别把 `auto` 写成「永远 bind」。
- **bind 判据看活文件，不看 mountinfo（v1.4.2）**：元模块可能在我们之后才叠加 `/my_product`，把早先的 bind 盖住；此时 mountinfo 里仍有本模块的 bind，按「已挂」跳过就会永远停在 3。所以 `auto` 用 `live_rate` 判断，只有 `always` 才用 mountinfo 去重。
- **策略覆盖开关**：`POLICY_ENABLE=0` 时 `post-fs-data.sh` 必须同时 `rm -rf $MODDIR/my_product`，否则上一次开机残留的副本仍会被元模块合并，开关看似无效。`POLICY_ENABLE`（生不生成副本）与 `POLICY_MOUNT`（自己挂不挂）正交，别合并成一个键。元模块可能在我们的脚本之前就完成合并，所以关开关后旧副本可能还会生效一轮开机——别为此在 `post-fs-data.sh` 里加同步等待。
- **策略文件词汇表**：`rateId` 0=未指定 1=90 2=60 3=120 4=144；文件头注释是过时的，只有尾部 `<config maxrefreshsettings="3">` 是真正的 120 截断总开关。
- **策略文件是单行 XML（v1.4.1 踩过）**：`maxrefreshsettings` 在头部注释里也出现一次，同一个 `sed s///` 必须带 `/g`，否则只改到注释那一个、尾部总开关仍是 `3`——症状正是「`policy_bind=yes` 但 `policy=maxrefreshsettings="3"`」。生成副本后要回读尾部校验并写 `post_fs.log`；`status` 的 `policy_module` 是副本自身的内容，用来区分「副本没改对」和「挂了没盖住」。副本一律先写临时文件再 `cat` 原地覆盖，别用 `sed 源 > 副本`（源已是本模块副本时会把文件截成空）。
- **未知格式的内核节点只记录不盲写**：`/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` 由 `discover()` 记日志；没有一手格式资料就先别 `echo`。
- **触控 IRQ 匹配关键字是 `touch`**（`touch-00`，本机 IRQ 288），不是 `touchpanel`；亲和性按 `smp_affinity` 十六进制掩码写。
- **`game_switch_enable` 内核按十六进制解析**，写 `1` 等于 MODE_GAME，和官方 HAL 兜底路径一致。
- **日志路径**：`/data/adb/p2p144/p2p.log`（>100KB 自动截断）、`post_fs.log`、备份 `backup.conf`。模块运行日志走这两处，别写 `/sdcard`（WebUI 的用户导出例外：`/sdcard/Download/DSH-Go/`）。