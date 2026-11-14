# AGENTS.md — pad2pro_144_touch

一加 Pad 2 Pro（OPD2413 / ColorOS 16）的 KernelSU / APatch / Magisk 模块：把「卡 120Hz 上不去 144」修好并锁 144，附带触控优化。策略覆盖副本走标准模块目录、**由元模块合并生效，本模块不自挂载**（v1.5.0）；没接管时退化为纯运行时方案（SF 强切+看门狗）。
纯 `/system/bin/sh`，**没有构建步骤**，改文件即改产物；README.md 是给用户看的说明，本文件是给改代码的 agent 看的约定。触控接口的一手源码依据见 `docs/touch-research-v1.5.md`。

## 验证方式（唯一可用手段）

本机是 Android 平板，不在 PC 上跑：

```sh
# 语法检查（每次改 .sh 都做，PC 上 sh -n 即可）
for f in *.sh tools/*.sh tools/archive/*.sh; do sh -n "$f" || echo "FAIL $f"; done

# 真机（需 root）
su -c "sh /data/adb/modules/pad2pro_144_touch/apply.sh status"   # 有元模块时 policy= 应为 maxrefreshsettings="4"
su -c "dumpsys display | grep -E 'mActiveModeId|mActiveRenderFrameRate'"
```

期望 `mActiveModeId=7`（144 档）、`mActiveRenderFrameRate=144.00002` 左右。无元模块时 `policy_source=runtime-only` 且 render 仍 144（退化不是故障）。

WebUI（真机）：模块卡 → WebUI → 状态页应显示「正常」（无元模块时策略卡为中性「运行时方案」）；点「导出日志」应在 `/sdcard/Download/` 出现 `pad2pro-doctor-*.txt`（页面不渲染日志，只显示两个日志文件的字节数/最后写入时间）。页面无 bridge 时只显示提示页，属正常。

## 结构与执行顺序

| 文件 | 角色 | 何时跑 |
|---|---|---|
| `customize.sh` | 安装器：校验机型 `ro.product.model == OPD2413`，否则 `abort`；给脚本 `set_perm 0755`；`POLICY_ENABLE=1` 时现场生成 `my_product/etc/refresh_rate_config.xml`（=0 则删掉）。输出只留结果行，不放 changelog | 安装时 |
| `post-fs-data.sh` | 从当前系统原件 `sed` 出覆盖副本到 `<模块>/my_product/etc/`（OTA 自适应、幂等）；`POLICY_ENABLE=0` 则移除副本；记录活文件是否已被元模块接管。**不做任何挂载** | 每次开机早期 |
| `service.sh` | 清残留 `daemon.pid` → `sleep 10` → 后台起 `apply.sh daemon`。（v1.5.0 删掉了 late_start 补跑 post-fs-data——它只为旧版 bind 兜底服务） | 开机 late_start |
| `apply.sh` | 核心：备份、settings 一次性写入（UI 一致性）、SF 强切（唯一运行期强制手段）、触控持久档位、单职责退避看门狗；子命令 `boot\|daemon\|once\|status` | 手动 / 守护 |
| `action.sh` | KSU 模块卡「操作」按钮 → `apply.sh once` + `status` | 用户点按 |
| `uninstall.sh` | 杀守护进程、按 `backup.conf` 还原（含旧版 game_switch 行兼容）、清 user-preferred mode、umount 历史残留、删 `/data/adb/p2p144` | 卸载时 |
| `config.conf` | 全部可调开关，被 `apply.sh` / `post-fs-data.sh` 以 `.` 加载 | — |
| `webroot/index.html` | 模块 WebUI：只读状态 + 日志文件大小/时间 + 一键导出日志到 `/sdcard/Download/`；**不渲染日志内容**；KSU/APatch 管理器用 WebView 打开 | 用户打开时 |
| `tools/*.sh` | 只读诊断脚本，**不参与安装**，不要被模块逻辑引用；`tools/archive/` 是一次性实验存档，不维护 | 排查时 |
| `docs/touch-research-v1.5.md` | 触控接口一手调研归档（档位表/节点矩阵/源码链接），改触控逻辑前先读 | — |

## 改代码时守住的约定

- **`MODDIR=${0%/*}`**：所有脚本用这一行定位自身目录，不要硬编码 `/data/adb/modules/...`（KSU 与 Magisk 布局、模块名都可能变）。
- **新增配置项要成对**：`config.conf` 加一行 + `apply.sh` 里 `VAR=${VAR:-默认值}` 兜底一行。缺兜底会在用户配置缺失时拿到空串。
- **settings 只是 UI 一致性，不是强制手段（v1.5.0）**：ColorOS 会把 `peak_refresh_rate` 改写成 `120.00001`，这属正常——看门狗**不再纠偏 settings**，唯一判据是实测帧率 `render_hz`，漂移只补 SF 1035。别把 settings 纠偏加回来（那是旧版拉锯的根源之一）。
- **版本号三处同步**：`module.prop` 的 `version` / `versionCode` + 相关脚本头部注释里的版本说明。`versionCode` 必须递增。当前 1.5.1 / versionCode 14。
- **幂等**：`post-fs-data.sh` 与 `apply.sh` 都可能在每次开机重复执行。写入前先比较当前值（如 `tp_level`），或让 sed 正则对已处理过的文件仍成立。
- **守护进程单例**：`alive()` 用 `PIDF` + `/proc/$p/cmdline` 含 `apply.sh` 双条件判断，避免重启后 PID 复用误判。改 `watch()`/`service.sh` 时保留这两条。
- **status 输出是接口**：`action.sh` 和 `tools/check_v12.sh` 都依赖 `apply.sh status` 的 `key=value` 行。加字段可以，别改已有键名。v1.4.0 新增 `daemon`、`target_hz`、`policy_enable`、`touch_switch`、`module_disabled`；v1.4.1 追加 `policy_module`；v1.5.0 追加 `policy_source`（meta/runtime-only/off）、`touch_sensitive`、`touch_smooth`。**语义变更**：`touch_switch` 现表示「持久档位优化是否启用」（原 TOUCH_GAME_SWITCH 已废弃）；`policy_bind` 保留但 v1.5.0 起恒为 no（历史残留除外）。
- **看门狗参数（v1.5.0）**：稳态 `WATCH_INTERVAL`（默认 10s）只查 render_hz；漂移补 SF 后 2s 复查；连续失败退避 `WATCH_INTERVAL*fails` 封顶 60s，成功归零；同因日志 `date +%s` 限频每分钟 ≤1 条；灭屏 20s。改节奏时保持「单职责 + 退避 + 限频」三件套，别往循环里塞别的巡检。

## WebUI 约定（单页状态 + 日志导出）

- **只读**：`webroot/index.html` 不写 `config.conf`、不触发 `apply.sh once`、不改系统设置；只读 status、复制、把日志导出到 `/sdcard/Download/`。
- **日志不渲染**：页面只显示 `p2p.log` / `post_fs.log` 的字节数与最后写入时间；日志内容一律**设备侧**合成（`{ ... } > 文件`），不经过 `exec` 的 stdout（桥有长度上限，整份 `cat` 回来会被静默截断，旧版「日志页空白」就是这么来的）。导出失败自动回退 `/data/local/tmp/`，toast 必须报出实际路径。**v1.5.1 起日志每次重启清空**（post-fs-data.sh 清 post_fs.log、apply.sh boot/daemon 清 p2p.log；once 不清），导出文件头部带 `boot_only=1` 标记。
- **零依赖**：单文件、内联 CSS/JS、无 CDN/外部字体/图标；只做深色模式。
- **命令写死**：所有 `exec` 命令由页面常量拼接，只有模块目录经 `shq()` 加引号；不接受页面输入拼 shell。
- **渲染安全**：状态一律 `textContent`，禁止把任何内容塞进 `innerHTML`。
- **反馈**：所有可点控件都要有 toast（动作 + 结果）；自动刷新静默，失败走红条 banner，不弹 toast。
- **模块目录**：不写死路径；先按 `module.prop` 的 `id` 扫 `/data/adb/modules/*`，回退 `/data/adb/modules/pad2pro_144_touch`。
- **桥差异**：KSU `exec` 返回 `{errno,stdout,stderr}`，APatch 返回字符串；页面适配层统一，并在命令末尾追加 `__RC=$?` 取真实退出码。不要依赖 `ksu.spawn`。
- **权限**：`webroot` 的权限/SELinux 由管理器设置，不要在 `customize.sh` 里 chmod。
- **状态判定（v1.5.1 结果导向）**：策略卡三态——`policy=4`→good「已生效」（文案不特指元模块，任何外部接管都算）；`policy_source=runtime-only` 且 render 达标→中性「运行时方案」（不算异常）；其余 policy≠4→warn「未生效」。触控卡以 `touch_sensitive/touch_smooth` 档位为主（人话：灵敏度/平滑），`game_switch` **不再上页面**（仅旧版 status 无档位字段时回退展示）；卡片 detail 一律人话，不放 key=value 技术黑话。
- **布局（v1.5.1）**：四卡 2×2 网格（<560px 单列）；无原始状态折叠面板（key=value 原文只通过「复制状态」按钮进剪贴板、或进导出文件）；「诊断与导出」区两按钮并排（导出日志 primary + 复制状态）+ 日志大小/时间参考行 + 一行缩略说明；顶栏只有模块名+版本+刷新状态+总体徽章；无页脚。
- **验收**：开发环境没有 `/data/adb`，真机最终以模块卡 WebUI 打开为准；改完先跑 `sh -n` 和页面 JS 语法检查。

## 已知坑（踩过的）

- **SF 事务码 `service call SurfaceFlinger 1035 i32 <id>`** 是运行期唯一实测有效的手段；id 从 `dumpsys SurfaceFlinger` 里抓 `vsyncRate=<TARGET_HZ>.00` 那条（v1.5.0 起由 TARGET_HZ 拼接，守护进程内缓存 `SF_ID`，补切后仍不达标才清缓存重解析），抓不到才用 `SF_FALLBACK_ID`。别再退回「只写 settings」。
- **`id 6` 与 `mActiveModeId=7` 不是同一个编号空间**：`1035 i32 6` 是 SF 侧 mode id（T4 实测有效），切完后 `dumpsys display` 看到的是 `mActiveModeId=7`（display 侧 144 档）。别把两个数字当成互相矛盾。
- **元模块（metamodule）是 KSU 的挂载基础设施**：`module.prop` 带 `metamodule=1` 的特殊模块（meta-overlayfs / Hybrid Mount / Magic Mount-rs / Mountify 等），同一时间只能装一个，负责把所有普通模块的分区目录合并进系统；**没装元模块则所有模块都不会被挂载**（KSU 官方文档明确）。挂载方式不统一：overlay（mountinfo 不可见）、magic mount/bind（可见）、VFS/nomount（没有真实挂载）；有些元模块默认不接管 `my_product`（例如 Magic Mount-rs 要 `extra_mount=["my_product"]`）。所以判断生效只看活文件内容 `maxrefreshsettings`，不看 `mount` 输出、不依赖任何元模块 CLI。参考 https://kernelsu.org/guide/metamodule.md 。
- **其他普通模块可能盖住本模块副本**：真机实测 extreme_gt（解锁帧率/温控的普通模块，不是元模块）自己 bind 了 `/my_product/etc/refresh_rate_config.xml` 叠在元模块合并层之上，活文件内容来自它而非本模块副本。这属正常竞争——本模块只关心活文件结果（=4 即达标），不区分来源、不对抗。`policy_source=meta` 的语义是「外部已接管」（含元模块合并或其他模块 bind），文案不特指元模块。
- **不自挂载（v1.5.0）**：bind 兜底逻辑与 `POLICY_MOUNT` 键已整体删除。没装元模块/没接管 my_product 时活文件停在 3 是**预期退化**，运行期由 SF+看门狗锁 144；`policy_source=runtime-only` 就是这个状态。别把 bind 加回来——历史上它和元模块叠加顺序互相盖（v1.4.2 的坑），维护成本大于收益。`uninstall.sh` 的 umount 仅清理历史版本残留。
- **策略覆盖开关**：`POLICY_ENABLE=0` 时 `post-fs-data.sh` 必须同时 `rm -rf $MODDIR/my_product`，否则上一次开机残留的副本仍会被元模块合并，开关看似无效。元模块可能在我们的脚本之前就完成合并，所以关开关后旧副本可能还会生效一轮开机——别为此在 `post-fs-data.sh` 里加同步等待。
- **策略文件词汇表**：`rateId` 0=未指定 1=90 2=60 3=120 4=144；文件头注释是过时的，只有尾部 `<config maxrefreshsettings="3">` 是真正的 120 截断总开关。
- **策略文件是单行 XML（v1.4.1 踩过）**：`maxrefreshsettings` 在头部注释里也出现一次，同一个 `sed s///` 必须带 `/g`，否则只改到注释那一个、尾部总开关仍是 `3`。生成副本后要回读尾部校验并写 `post_fs.log`；`status` 的 `policy_module` 是副本自身的内容，用来区分「副本没改对」和「元模块没接管」。副本一律先写临时文件再 `cat` 原地覆盖，别用 `sed 源 > 副本`（源已是本模块副本时会把文件截成空）。
- **未知格式的内核节点只记录不盲写**：`/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` 由 `discover()` 记日志；官方内核分支里 grep 不到这两个确切路径的创建者（可能闭源 ko），没有一手格式资料就先别 `echo`。**真机实测它们是目录不是文件**（旧版 `head -c` 读目录永远为空，v1.5.0 已改为枚举文件名）。同名官方实现实为 sysfs `cpu*/touch_boost/`（CPU 提频）与 `/proc/sys/fbg/`（调度 boost），都不是触控报点。
- **触控 IRQ 编号每次开机都变**（真机实测 288→343→279→282…），必须动态从 `/proc/interrupts` 解析，别硬编码；匹配关键字 `touch` 稳定命中。
- **场景通道与直写档位并存不冲突**：`touch_scene_para` 的 `sensitive_level:0` 是按包名/activity 的增量层，proc 直写的 chosen 档（如 4）不被它覆盖；官方 `touch_scene_default_para` XML 内容全是 `pen_sensitive_level`（手写笔锁点），不管手指灵敏度——这是「直写档位零拉锯」的真机佐证。
- **触控 IRQ 匹配关键字是 `touch`**（`touch-00`，本机 IRQ 288 / GPIO 162），不是 `touchpanel`；亲和性按 `smp_affinity` 十六进制掩码写。
- **game_switch 的三个一手结论（v1.5.0 调研，详见 docs/touch-research-v1.5.md）**：① 本机（NT36536/v2 栈/erhai DTS）写非 0 **只发固件 GAME_ON 命令**，无 smooth/sensitive/major_rate 副作用（DTS 无对应 support，README 旧描述有误）；② v2 栈灭屏清固件但不清 noise_level，**亮屏自动恢复**游戏模式与档位——不需要看门狗防灭屏丢失；③ common 层只做 `value>0` 布尔判断，社区 node 26 十六进制魔法值档位表属闭源 touchDaemon framework_mode 路径，本机无该节点，别照抄。因此 v1.5.0 起**不再写 game_switch**，改持久档位 `sensitive_level`/`smooth_level`（chosen 档亮屏自恢复；系统改档/充电插拔切 charging 表都接受不反写）。
- **触控档位方向未验证**：DTS 数值越小 presumably 越灵敏，固件语义闭源；真机手感反了只改 config 默认值（0=厂商默认，-1=不碰节点），别改代码逻辑。`pen_sensitive_level` 场景键动手写笔管线，刻意不碰。
- **日志路径**：`/data/adb/p2p144/p2p.log`（>100KB 自动截断）、`post_fs.log`、备份 `backup.conf`。模块运行日志走这两处，别写 `/sdcard`（WebUI / `tools/check_v12.sh` 的用户导出例外：`/sdcard/Download/`，文件名前缀 `pad2pro-`）。