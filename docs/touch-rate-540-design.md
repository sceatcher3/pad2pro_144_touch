# 全局 540Hz 触控采样：可行性与方案（v1.6.2）

日期：2026-11-17（2026-11-18 更新）　状态：**调研完成；写回避让已实现（v1.6.2，IRQ 差值法）；报点率 2× 显示绑定为用户观察，gs 作用待受控实测**
目标：把「全局触控率」提到本机面板支持的 540Hz，并回答「能否像 `refresh_rate_config.xml` 那样靠挂载文件解决」。

相关：[touch-research-v1.5.md](touch-research-v1.5.md)（触控栈/档位表）、[v1.6-pin-design.md](v1.6-pin-design.md)（守护）、`apply.sh`（`touch_gs_write` / `touch_guard`）、`tools/touch_rate.sh`（实测工具）。

---

## 0. 结论摘要

1. **本机内核栈没有「报点率」旋钮。** `/proc/touchpanel/report_rate` 节点被 `report_rate_v2_support` 和 `ts_ops->report_rate` 双重门控；NT36536 驱动没有该回调、erhai DTS 也没有该属性 → **节点根本不创建**。`game_switch_enable` 写入里那个 `high_frame_rate:<v><t>` 载荷同样被 `set_high_frame_rate` + `high_frame_rate_support` 门控，本机两者皆无 → **空操作**。
2. **系统侧唯一暴露给用户态的入口是 `game_switch_enable=1`（固件 `EVENTBUFFER_GAME_ON`）。** 这不是本模块的猜测：LineageOS `hardware_oplus` 的 `HighTouchPollingRate` HAL 把「高触控轮询率」直接实现为写这个节点。
3. **「挂载文件改触控率」在本机栈不成立。** 唯一能被 `request_firmware` 加载、因而可被模块目录覆盖的触控配置是 `*_sys_touch_scene_config.xml`，但内核场景解析器只认 5 个键（`screen_lock_mode` / `sensitive_level` / `set_package_type` / `pen_sensitive_level` / `touch_leave_jitter`），**没有报点率键**。
4. **所以「全局 540Hz」= 全局 pin `game_switch_enable=1` + 实测确认固件真的升频。** 若实测发现 gs=1 仍是 120Hz ≈ 8.3ms/帧，说明 540Hz 只在固件内部条件（或本机没有的闭源 `framework_mode`/node 26 路径）下启用，**用户态没有别的办法**——不要为此去改触摸固件。
5. **社区「全局高采样率」模块全部依赖别的栈**：murongtouch 走 `hbp` code、PLF110 走 Binder node 182 / white_list（S3910 等），本机没有这些节点；murongtouch 自己写明「hbp code ≥16 会让触控停止报点」，PLF110 注明高报点率会增加功耗发热——**不要照抄到本机**。公开资料里没有任何模块做到 540Hz，也没有 OPPO 平板的 getevent 实证。
6. **报点率与显示绑定（2026-11-18 用户真机观察）**：报点率≈2×显示刷新率（144Hz 显示→≈288Hz）；**540Hz 采样仅 90Hz 显示档可达**（540=6×90），与本模块保 144 显示的目标互斥 → **「144Hz 显示 + 540Hz 触控」本机不可达，144 下现实上限≈288Hz**。此为用户侧观察证据（非内核源码证据）；gs=1 是否解锁 2× 绑定（相对 gs=0 的默认 120Hz）仍待 `tools/touch_rate.sh` 受控实测。

---

## 1. 一手证据

| # | 事实 | 一手来源 |
|---|---|---|
| 1 | `/proc/touchpanel/report_rate` 注册条件 = `ts->report_rate_v2_support`；写函数还要求 `ts_ops->report_rate` | `touchpanel_proc.c`（node 表 L6071、`proc_report_rate_write` L2494-2537）、`touchpanel_common_driver.c` L2398 |
| 2 | NT36536 的 `nvt_ops` 没有 `report_rate` / `set_high_frame_rate` 回调 | `nvt_drivers_nt36536_noflash.c` ops 表 L5630-5655 |
| 3 | erhai DTS 没有 `report_rate_v2_support` / `report_rate_white_list_support` / `major_rate_limit_support` / `touchpanel,high-frame-rate-time` | [erhai-oplus-tp-24924.dtsi](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/blob/oneplus/sm8750_b_16.0.0_pad_2_pro/kernel_platform/qcom/opensource/devicetree/oplus/tp/erhai-oplus-tp-24924.dtsi)（与速率相关的只有 `game_switch_support`；`report_rate_limit` 没有值，`of_property_read_u32` 读失败后按 60Hz 兜底，只影响健康监控阈值） |
| 4 | `game_switch_enable` 写 `1` → `ts_ops->mode_switch(MODE_GAME, true)` → `nvt_enable_game_mode()` → 固件 `EVENTBUFFER_GAME_ON(0x7D)` | `touchpanel_proc.c` L1054-1125、`nvt_drivers_nt36536_noflash.c` L3163-3178 |
| 5 | 「高触控轮询率」HAL 写的就是 `game_switch_enable` | [LineageOS hardware_oplus HighTouchPollingRate.cpp](https://github.com/LineageOS/android_hardware_oplus/blob/lineage-23.0/aidl/touch/HighTouchPollingRate.cpp) |
| 6 | 场景通道键集只有 5 个，无速率键 | `touchpanel_common.h` L203-219（`buffer_scen[]` / `scene_type`） |
| 7 | 场景配置文件由 `request_firmware` 加载（因此理论上可被模块目录覆盖） | `touchpanel_proc.c` `touch_scene_default_para_read()` L3113-3212：`<fw 前缀> + "/sys_touch_scene_config.xml"`，失败再试 `*_sys_touch_scene_config.img` |
| 8 | 面板规格：触控采样率最高 540Hz、默认 120Hz；屏幕 144Hz | OPPO 商城 / ZOL 参数页（见 §7） |
| 9 | NT36536 的扩展命令表里**没有** `EVENTBUFFER_EXT_REPORT_RATE`（0x14 空缺：0x13 之后直接 0x15）→ 固件层没有「设 Hz」命令 | `nvt_drivers_nt36536_noflash.h` L83-107 |
| 10 | `my_product/etc/` 里被证实的可挂载配置都是**显示类**（`refresh_rate_config.xml`、`sys_game_manager_config.json` 等），**触控速率配置查不到** | 社区 ColorOS 移植笔记（见 §7）、本仓库既有实践 |

每帧间隔换算：120Hz≈8.3ms、240Hz≈4.2ms、540Hz≈1.85ms。实测用 `tools/touch_rate.sh`：读 `/proc/interrupts` 里触摸 IRQ 的计数差 / 采样秒数（不用 `getevent`，管道被 kill 时会丢 stdio 缓冲的尾部）。

---

## 2. 「触控率」在本机由谁决定

```
用户态 / ColorOS 游戏助手
   └─ 写 /proc/touchpanel/game_switch_enable = 1
        └─ 内核 proc_game_switch_write()
             ├─ (可选) high_frame_rate 载荷 → 本机无回调, 空操作
             └─ mode_switch(MODE_GAME, true) → nvt 发固件 EVENTBUFFER_GAME_ON(0x7D)
                  └─ 固件内部决定: 报点率 / 滤波 / 噪声策略（闭源, 无内核接口可读）
```

结论：**「540Hz」不是内核参数，是固件在 GAME_ON 之后的内部行为**。用户态只能「请求游戏模式」，不能指定 Hz。是否真的到 540Hz，必须实测（`tools/touch_rate.sh`）。

---

## 3. 三条路线对比

| 路线 | 做法 | 可行性 | 代价/风险 |
|---|---|---|---|
| **A. 运行时全局 pin（推荐）** | `TOUCH_GAME_SWITCH=1` 开机写一次 + 守护维护；`tools/touch_rate.sh` 实测 | ✅ 唯一有源码依据的路径 | 每次写 proc 持触控锁 ≥20ms；固件可能仍 120Hz；非游戏场景也开 GAME_ON（功耗/防误触未知） |
| B. 挂载配置覆盖 | 仿 `refresh_rate_config.xml`，在模块 `my_product/etc/` 放触控配置文件由元模块合并 | ❌ 现有栈无速率配置；场景 XML 无速率键；`my_product/etc` 被证实的只有显示配置 | 除非真机找到 ColorOS 私有白名单（§5 待证） |
| C. 改触摸固件 | 覆盖 `request_firmware` 加载的 `0x2XN242CN00*.bin` | ⚠️ 理论可行、工程上不可取 | 签名/校验/变砖风险，版本一升级就失效，绝不默认做 |

---

## 4. 推荐方案（A）：全局游戏模式 + 实测闭环

### 4.1 已经具备的部分（v1.6.1/v1.6.2）

- `TOUCH_GAME_SWITCH=1`：开机 `touch_gs_write` 写一次；`TOUCH_GUARD=pin` 时系统改回 0 就按每分钟上限写回。
- 这就是「全局高轮询率」的完整实现——**不需要再挂任何文件**。

### 4.2 必须补的两件事

**① 写回要避开报点活动（v1.6.2 已实现）**

内核在 `ts->mutex` 内发固件命令：`nvt_extend_cmd2_store()` / `nvt_cmd_store()` 每次 `msleep(20)`、最多 5 次重试；而报点线程 `tp_irq_thread_fn()` 要拿同一把锁（本机 `int_mode = BANNABLE`）。所以守护每次写档位/游戏模式，最坏会让报点停 20–100ms。

**`fd_touch_count` 不可用**（2026-11-18 源码核实，推翻本节旧设计）：该节点受 `face_detect_support` 门控（`touchpanel_proc.c` L6145），erhai DTS 无该属性 → **节点根本不创建**；即使存在，它读出的 `touch_count & 0x0F` 是 `finger_num_center`——只在人脸检测开启（`fd_enable`）时统计**上半屏中心区**（`y < max_y/2` 且距左右缘 >30px）的手指（`touchpanel_common_driver.c` L1085-1089），FPS 摇杆/下半屏手指全漏。本机也没有其他不持锁就能读手指/报点活动的现成 proc 节点（`irq_depth` 读 IRQ 禁用深度+GPIO 电平；debug_info 类全持 `ts->mutex` 还 disable_irq；`report_rate_test` 是主动阻塞测量，不适合每秒巡检）。

**已实现方案：触摸 IRQ 计数差值**（`apply.sh` `touch_irq_sum()` / `touch_busy()` / `write_gate()`）：

- 写回前读 `/proc/interrupts` 触摸行计数和，隔 150ms 再读一次（读取不持 `ts->mutex`）。计数增长 = 报点正在流动，此时写会卡报点线程 → 暂缓；不增长 = 无报点流量（手指抬起，或静止不出报点）→ 写回安全。这直接测量「卡顿的成因」（报点流量），比「手指按下」更贴合实际危害。
- `defer` 只在确有漂移要写回时累加，每 tick 至多 +1，暂缓不计入 `writes` 上限；连续避让达 `TOUCH_GUARD_DEFER_MAX`（默认 10 ≈10s）强制写一次，避免持续触控时永远不写回。
- 每 tick 最多探测一次（结果按 tick 缓存）；无漂移时不探测、不记日志。`log` 模式不写节点、不经过门，行为不变。
- 强制写回与每分钟上限日志各自独立节流桶（各 ≤1 条/分钟），不与暂缓/写回日志互吞——这两条是 P2 诊断跳帧的关键事件。
- 测试床 7 场景验证通过（空闲立即写/活跃暂缓+强制/无漂移零开销/log 模式不变/节点缺失 fail-open/上限仍生效/灭屏不写）。真机验收见 agent-notes §真机验收清单 #6。

**② 用实测决定「值不值得开」**

```sh
# 停守护，避免 1s 内被改回去
su -c 'kill $(cat /data/adb/p2p144/guard.pid)'
su -c 'echo 0 > /proc/touchpanel/game_switch_enable'
su -c 'sh /data/adb/modules/pad2pro_144_touch/tools/touch_rate.sh 5'   # 手指持续画圈/快甩
su -c 'echo 1 > /proc/touchpanel/game_switch_enable'
su -c 'sh /data/adb/modules/pad2pro_144_touch/tools/touch_rate.sh 5'
```

判读：

| 现象 | 含义 | 动作 |
|---|---|---|
| gs=1 时 avg≈288Hz（gap≈3.5ms，144 显示） | GAME_ON 解锁 2× 绑定（用户观察模型） | 保留 `TOUCH_GAME_SWITCH=1` + pin；288 即 144 显示下现实上限 |
| gs=0/1 都是 ~120Hz | 固件不认 GAME_ON，或 2× 绑定另有条件 | 关掉（`-1`），别折腾固件 |
| gs=1 且 **90Hz 显示**时 avg≈540Hz（gap≈1.9ms） | 与用户观察一致：540 仅 90Hz 档 | 与保 144 互斥，本模块不追求；记录结论 |
| 慢滑 ~120、快甩更高 | 固件按手指速度自适应 | 「固定 540」不存在，接受自适应 |

> 静止时没有报点，测出来 0 是正常的；测的时候必须真的在滑。

### 4.3 如果 gs=1 没提升

按 §0.4/§0.6 收手：本机用户态没有别的通道，且 540Hz 与保 144 显示互斥（仅 90Hz 显示档可达）。可选替代是「保证 144 显示 + 288Hz 触控下的稳定性」——也就是 v1.6.2 已经做的档位 2/3 + 报点活动避让写回（IRQ 差值法）。

---

## 5. 挂载文件路线：为什么现在不成立，以及什么条件下能成立

### 5.1 现有栈里能挂的触控配置只有一个

`touch_scene_default_para` 的底层文件由 `request_firmware()` 加载，名字由 `panel_data.fw_name` 推导：

- 默认场景 XML：`<fw 前缀>/sys_touch_scene_config.xml`
- 回退镜像：`<fw 前缀>_sys_touch_scene_config.img`

真机上用下面命令定位（`/vendor/firmware`、`/odm/firmware` 都可能在）：

```sh
su -c 'find /vendor/firmware /odm/firmware -iname "*touch_scene*" 2>/dev/null'
su -c 'dmesg | grep -iE "fw_name|touch_scene_config" | tail -20'
```

但这文件**不解决问题**：内核按 5 个键解析（§1 #6），没有任何与报点率/高刷相关的键。挂载它最多能改 `sensitive_level`（与我们现在直接写 proc 等价）和手写笔参数。

### 5.2 什么条件下挂载路线能成立

只有当 ColorOS 用户态自己「读一个配置文件 → 决定写 `game_switch_enable`」时，覆盖那个文件才有意义。**目前没有任何证据**（内核源码里不存在；HAL 是直接写节点；游戏助手行为闭源）。要确认，需要在真机上枚举：

```sh
# a) /my_product/etc 里和触控/游戏相关的配置（refresh_rate_config.xml 同目录风格）
su -c 'ls -la /my_product/etc' | grep -iE 'touch|game|switch|scene'
# b) 全盘找「会被读的」触控/游戏配置文件
su -c 'find /my_product /odm /vendor /system_ext /product -maxdepth 5 \
  \( -iname "*touch*" -o -iname "*scene*" -o -iname "*game*switch*" \) 2>/dev/null'
# c) 直接搜谁引用了这些关键字（二进制也搜，结论仅供参考）
su -c 'grep -rl "game_switch_enable\|high_frame_rate\|report_rate" \
  /my_product/etc /odm/etc /vendor/etc 2>/dev/null | head'
# d) ColorOS 触控/游戏助手进程改了谁：写 0 的瞬间抓一层
su -c 'ls -l /proc/touchpanel/game_switch_enable'
```

已证实可挂载的 `/my_product/etc` 配置都是显示类（`refresh_rate_config.xml`、`sys_game_manager_config.json`、`sys_graphic_enhancement_config.json`），触控速率配置**查不到**；特征 XML（`my_product/etc/permissions/*.xml`）里也没有触控速率 feature。

**判定标准**：只有找到「改它能稳定让 gs 保持 1 / 让报点率变化」的文件，才值得接入模块的 `my_product/etc/` 覆盖流程（`post-fs-data.sh` + `customize.sh` 两处同步生成 + 校验，参照策略副本）。找不到就明确不做——不要为了「像刷新率那样挂个文件」而凭空造一个没人读的文件。

### 5.3 如果将来找到（接入模板）

1. `customize.sh` / `post-fs-data.sh` 各加一段：从系统原件 `cp` 到 `<模块>/my_product/etc/<文件>`，再按需 `sed`（幂等、先写临时文件再原子覆盖）。
2. 回读校验失败就保留旧副本，写 `post_fs.log`。
3. `apply.sh status` 追加一个键（如 `touch_rate_cfg=`）报告「活文件是否被合并」，不改旧键名。
4. 仍然保留 `game_switch_enable` 的运行时兜底（配置只决定系统行为，不保证它真的写）。

---

## 6. 风险与放弃条件

| 风险 | 说明 | 处理 |
|---|---|---|
| 功耗/发热 | 540Hz 采样 + 144Hz 显示，触控 IC 与 CPU 唤醒都更多 | 实测对比 10 分钟功耗/温度；不接受就回 `-1` |
| 手感变差 | 高报点 + 低抗抖会更「抖」（v1.6.2 已把档位调到 2/3 抵消） | 先 2/3，再考虑 4/1 是否值得 |
| 非游戏场景副作用 | 全局 GAME_ON 可能改变防误触/边缘/掌托策略 | 观察桌面/笔记/阅读场景；必要时改成前台应用触发（工程量大，未做） |
| 写回卡顿 | 每次写 proc ≥20ms | §4.2 ① 的避让（v1.6.2 已实现：IRQ 差值法） |
| 误判「540」 | 固件可能只在快滑时升频；静态测不出 | 用 `touch_rate.sh` 分别测慢滑/快甩，多测几次看 avg 是否稳定 |
| 照抄别的栈的模块 | murongtouch 的 hbp code / PLF110 的 node 182 在本机不存在；写错 hbp code 会**直接停止报点** | 只做本机已证的 proc 写，不引入外来命令 |

**放弃条件**：gs=0/1 两态实测 avg 无差别（都 ≈120Hz），且 `/proc/touchpanel` 下找不到任何速率节点 → 判定本机用户态不可控，保持 `TOUCH_GAME_SWITCH=-1`，文档记录结论，不再尝试。若 gs=1 实测 ≈288Hz（2×144）→ 2× 绑定生效，保留 `=1`，接受 288 为 144 显示下现实上限；「全局 540 + 144 显示」已由用户观察（540 仅 90Hz 显示档）确认互斥，不为此追求。

---

## 7. 参考

- OnePlusOSS 本机分支：`nvt_drivers_nt36536_noflash.c/h`、`touchpanel_proc.c`、`touchpanel_common_driver.c`、`touchpanel_common.h`、`erhai-oplus-tp-24924.dtsi`
  （均为 `oneplus/sm8750_b_16.0.0_pad_2_pro`，链接见 [touch-research-v1.5.md §7](touch-research-v1.5.md)）
- [LineageOS hardware_oplus — HighTouchPollingRate.cpp](https://github.com/LineageOS/android_hardware_oplus/blob/lineage-23.0/aidl/touch/HighTouchPollingRate.cpp)
- 面板规格：一加平板 2 Pro「触控采样率最高 540Hz、默认 120Hz」——
  [OPPO 商城](https://www.opposhop.cn/cn/web/products/33997.html)、[ZOL 参数页](https://nb.zol.com.cn/993/9930255_param.html)
- 社区参考（**都是别的触控栈，只借结论不照抄**）：
  - [murongtouch](https://github.com/murongruyan/murongtouch)（ColorOS 17 / 真我 GT8 Pro，hbp/white_list 多后端，自带看门狗对抗 touchDaemon；写明 hbp code ≥16 会停报点）
  - [PLF110-Touch-Rate-Sync](https://github.com/lenluxue/PLF110-Touch-Rate-Sync)（S3910，Binder node 182，只接受 120/180/240/288/360）
  - 一加社区实测讨论（游戏模式是否真的抬报点率，含「仍读 120」反证）：[thread/5538866](https://bbs.oneplus.com/thread/5538866)、[thread/5719435](https://bbs.oneplus.com/thread/5719435)
- ColorOS 移植笔记（`my_product/etc` 可挂载配置清单）：[irvingwu.top](https://www.irvingwu.top/posts/coloros-port-guide)
- 本仓库：`tools/touch_rate.sh`（实测）、`apply.sh`（`touch_gs_write`/`touch_guard`）、[touch-research-v1.5.md](touch-research-v1.5.md)