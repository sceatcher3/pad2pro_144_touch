# 触控接口调研精华（v1.5.0 方案依据）

调研时间：2026-11。对象：一加 Pad 2 Pro（OPD2413 / erhai / 项目号 24924，NT36536 触控，ColorOS 16）。
一手来源：OnePlusOSS 内核**本机专属分支** `oneplus/sm8750_b_16.0.0_pad_2_pro` + LineageOS hardware_oplus HAL。
本文是结论归档；完整推导过程见当次会话调研报告。所有「本机存在/不存在」判断来自官方 DTS+驱动源码，置信度高，但 OTA 可能换栈，最终以真机枚举为准（`tools/probe_oplus.sh`）。

## 1. 本机触控栈身份（DTS 一手）

[erhai-oplus-tp-24924.dtsi](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/blob/oneplus/sm8750_b_16.0.0_pad_2_pro/kernel_platform/qcom/opensource/devicetree/oplus/tp/erhai-oplus-tp-24924.dtsi)：

- 芯片 `novatek,nf_nt36536`，IRQ GPIO **162**（与 README 实测 IRQ 288 / touch-00 吻合），面板 2400x3392。
- 驱动为 **v2 栈**（`oplus_touchscreen_v2/`）。
- 有：`game_switch_support`、`smooth-level`/`sensitive-level` 数组、`tp_scene_para_switch_support`、`incell_screen`、`pen_support`。
- **没有**：`major_rate_limit_support`、`report_rate_white_list_support`、`report_rate_v2_support`、`high_frame_rate_support`、`game_perf_para_default`。

## 2. 修正的两处旧认知（README v1.4.x 有误）

| 旧说法 | 一手源码结论 |
|---|---|
| 「写 game_switch 非 0 时固件同时把 smooth/sensitive 置默认值、major_rate_limit_times=0x0F」 | **对本机不成立**。v2 proc 写入里那两个副作用都有 `!array_support` / `major_rate_limit_support` 守卫，本机 DTS 全不满足。本机写 1 的唯一效果 = 给固件发 GAME_ON 命令（Novatek event-buffer 0x7D）+ 记录 noise_level。 |
| 「灭屏会丢游戏模式，需要看门狗补写」 | **半个理由不成立**。v2 栈灭屏只对固件发 MODE_GAME,false，不清 `ts->noise_level`；亮屏 `speedup_resume → operate_mode_switch` **自动恢复**游戏模式并重放 smooth/sensitive chosen 档。真正的拉锯对手只有 ColorOS 用户态（游戏助手/触控服务经 HAL node 26 写 0，时机闭源）。 |

另：MODE_GAME 在内核 common 层只做 `value > 0` 布尔判断，**没有位掩码档位表**；社区流传的 node 26 十六进制魔法值（12c=360Hz 等）属于闭源 touchDaemon 的 framework_mode 路径，本机无该节点，直写 proc 不经过那张表，**不要照抄**。

## 3. 节点可用性矩阵（本机）

| 节点 | 存在 | 可写 | 说明 |
|---|---|---|---|
| `/proc/touchpanel/game_switch_enable` | ✅ | ✅ | 读出形如 `1, high_frame_support:0, high_frame_value:0`（noise_level 十进制）。v1.5.0 起本模块不再写它。 |
| `/proc/touchpanel/sensitive_level` | ✅ | ✅ | 0-5 选档，负数=raw 固件值直写。chosen 档亮屏自动重放。**v1.5.0 主用**。 |
| `/proc/touchpanel/smooth_level` | ✅ | ✅ | 同上。**v1.5.0 主用**。 |
| `/proc/touchpanel/touch_scene_para` | ✅ | ✅ | 官方场景通道，格式 `名字:整数;名字:整数`；关键字含 `sensitive_level`/`set_package_type` 等。系统按场景下发参数的同通道入口（备选，未采用）。`pen_sensitive_level` 动手写笔管线，**别碰**。 |
| `/proc/touchpanel/touch_scene_default_para` | ✅ | 只读 | 厂商默认场景 XML（request_firmware 加载）。探针已补采。 |
| `/proc/touchpanel/report_rate*`、`high_frame_rate` | ❌/no-op | — | DTS 无 support 或 NT36536 无回调。报点率由固件按显示刷新率自适应，用户态无旋钮。社区 182 节点属 S3910/hbp 栈，不适用本机。 |
| `/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` | ✅ **是目录** | 未知 | 真机探针（2026-11-15）证实两者存在但为**目录**（旧版 `head -c` 读目录永远为空，已改为枚举文件名）。本分支源码 grep 不到创建者（可能闭源 ko）。**维持只记录不盲写**。同名官方实现实为 sysfs `/sys/devices/system/cpu/cpu*/touch_boost/`（CPU 提频，非触控报点）与 `/proc/sys/fbg/`（调度帧率 boost）。 |
| `framework_mode` | ❌ | — | 本机探针实测不存在（README 既有结论）。 |

## 4. 档位表（DTS 一手，NT36536）

| 档 | smooth raw | sensitive raw | sensitive(充电) |
|---|---|---|---|
| 0 | 255（厂商默认） | 255 | 255 |
| 1 | 32 | 20 | 30 |
| 2 | 64 | 15 | 20 |
| 3 | 96 | 12 | 15 |
| 4 | 128 | 10 | 12 |
| 5 | 254 | 5 | 7 |

- raw 值语义闭源（sensitive→EVENTBUFFER_EXT_JITTER_LEVEL 0x0C，smooth→EXT_SMOOTH_LEVEL 0x0D）；数值越小 presumably 越灵敏/越少平滑，**方向需真机 A/B 验证**，反了只改 config 默认值。
- 持久性：chosen 档存 `ts`，亮屏 resume 自动重放。覆盖来源：(a) 系统设置/游戏助手改档（官方意图，不对抗）；(b) **充电插拔切 charging 数组**（接受，不补写；proc 只能写 chosen，charging 表改不了）。

## 5. v1.5.0 采用的方案与理由

**开机/手动应用时写一次 `sensitive_level=4`、`smooth_level=1`，彻底放弃常驻 game_switch；看门狗不维护触控。**

- 零拉锯：不再与 ColorOS 用户态每 5s 互相重写；系统改档属官方意图，接受覆盖。
- 依据：§2（本机 game_switch 收益仅一条固件命令，价值待 A/B）、§4（chosen 档自恢复）。
- 节点不存在（OTA 换栈）→ 跳过并记日志，退化为仅 IRQ 亲和性；绝不盲写。
- 卸载还原两档位（backup.conf 新增 sensitive/smooth 行）；旧备份的 game_switch 行兼容还原。
- 备选未采用：事件驱动游戏白名单开 game_switch（工程量大、前台检测在 ColorOS 分屏/浮窗下需实测）；`touch_scene_para` 同通道写档位（与直写 proc 效果等价，多一层解析，留作后续）。

## 5b. 真机探针回证（2026-11-15，v1.5.0 装机后首采）

设备：OPD2413 / ColorOS 16.0.10.600(CN01) / 内核 6.6.118-android15-8 / my_product 24926_1610_B。
以下全部来自 `pad2pro_probe.txt` 原始输出，**一手实测**，修正/确认调研推断：

| 项 | 实测值 | 结论 |
|---|---|---|
| `game_switch_enable` 读出 | `0, high_frame_support:0, high_frame_value:0` | ✅ 与 B1 预测的 v2 格式完全一致；模块不写它后稳定为 0（系统自管） |
| `sensitive_level` / `smooth_level` | `4` / `1` | ✅ 节点存在、写入成功、探针时（开机后 3 分钟）仍保持 |
| `touch_scene_para` 当前值 | `screen_lock_mode:0 sensitive_level:0 set_package_type:0 pen_sensitive_level:254 touch_leave_jitter:0` | ⚠️ 场景通道的 sensitive_level=0 与 proc 直写的 chosen=4 **并存不冲突**——场景通道是另一层（按包名/activity 增量），直写档位不被它覆盖 |
| `touch_scene_default_para` | 完整 XML（version 2025060510），内容**全是 pen_sensitive_level**（手写笔锁点：默认 254，文件管理/相册等 15，笔记/绘画类 3） | ✅ 官方场景配置只管手写笔，不管手指灵敏度——进一步支持「直写 sensitive_level 不与系统拉锯」；也印证 pen 管线刻意不碰是对的 |
| `/proc/oplus_touch_boost`、`/proc/oplus_frame_boost` | **存在，但是目录**（`ls /proc` 可见；`[ -f ]` 判否） | 🔧 旧 discover() 用 head -c 读目录永远为空（日志里 `发现 oplus_touch_boost=` 即此因）；已改为枚举目录内文件名，仍不盲写 |
| `/odm/bin/touchHidlTest` | 存在（52064 字节，2026-09-11） | Binder 触控通道可用（备选方案②的基础设施在位，本版未用） |
| `incell_panel` / `charge_detect` | `1` / `0` | ✅ incell 确认（灭屏 MODE_GAME,false 路径适用）；探针时未充电 |
| IRQ | 每次开机编号不同（288→343→279→282…），匹配关键字 `touch` 稳定命中 | ✅ 动态解析 IRQ 的设计正确，不能硬编码 288 |
| 策略活文件 | `maxrefreshsettings="4"`，mountinfo 归因 `/adb/modules/extreme_gt/my_product/etc/...` | ⚠️ 实际最上层是 **extreme_gt（普通模块，解锁帧率/温控）自己的 bind**；KSU 元模块（metamodule，挂载基础设施）已把本模块副本合并进系统但被 extreme_gt 盖住。本模块 `policy_source=meta` 按活文件内容判定，语义=「外部已接管」（含元模块合并或其他模块 bind），v1.5.1 起文案不特指元模块 |
| SF 模式表 | `mSfDisplayModes` id=6 → vsyncRate=144.00002；`mActiveSfDisplayMode id=6`；display 侧 `mActiveModeId=7` | ✅ 再次证实两个编号空间；`sf_mode_id` 的 grep 模式 `vsyncRate=144.00` 能命中 `144.00002`（前缀匹配） |
| `mDisplayModeSpecs` | `primary=physical:(144.0 144.0) render:(144.0 144.0)` | ✅ 策略覆盖+SF 强切后 render range 不再被压 120 |

**旧版拉锯实锤**（p2p.log 历史段）：11-10 至 11-15 凌晨共 40+ 条 `game_switch 漂移(0), 重写`，以及 11-10 18:08–18:14、11-14 01:04–01:14 两段每 5s 一条的 `实测 120Hz != 144Hz, 重新应用(settings+SF)` 刷屏（各持续 6–10 分钟）——正是 v1.5.0 退避+限频+单通道要消灭的形态。v1.5.0 启动后（01:00:05 起）日志干净，无漂移无重写。

## 6. 真机验证命令（验收清单触控部分）

```sh
su -c 'cat /proc/touchpanel/smooth_level /proc/touchpanel/sensitive_level'
su -c 'echo 4 > /proc/touchpanel/sensitive_level; echo 1 > /proc/touchpanel/smooth_level'
# 灭屏→亮屏后回读是否保持；插拔充电器后回读；进/出游戏后回读
su -c 'cat /proc/touchpanel/touch_scene_default_para'   # 官方场景 XML
su -c 'sh /data/adb/modules/pad2pro_144_touch/tools/probe_oplus.sh'  # 全量探针回传
```

## 7. 一手源码索引

- [v2 touchpanel_proc.c](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/blob/oneplus/sm8750_b_16.0.0_pad_2_pro/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/touchpanel_proc.c)（game_switch 写入 L1054-1125 / 读出 L1127-1143；档位 L2890-3036；场景 L3222+）
- [v2 touchpanel_common_driver.c](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/blob/oneplus/sm8750_b_16.0.0_pad_2_pro/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/touchpanel_common_driver.c)（suspend L4836 / resume 恢复 L355-364 / 充电切换 L397-435）
- [NT36536 驱动](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750/blob/oneplus/sm8750_b_16.0.0_pad_2_pro/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/Novatek/NT36536_noflash/nvt_drivers_nt36536_noflash.c)（GAME_ON/OFF 0x7D/0x7E L3163-3178；nvt_ops 无 report_rate 回调 L5630-5653）
- [LineageOS HighTouchPollingRate.cpp](https://github.com/LineageOS/android_hardware_oplus/blob/lineage-23.0/aidl/touch/HighTouchPollingRate.cpp)（node 26 = game_switch；无 HAL 时兜底直写 proc）
- [OplusTouchConstants.h](https://github.com/LineageOS/android_hardware_oplus/blob/lineage-23.0/aidl/touch/touch-headers/OplusTouchConstants.h)
- 社区参考（工程模式，非本机接口）：[PLF110-Touch-Rate-Sync](https://github.com/lenluxue/PLF110-Touch-Rate-Sync)（事件驱动+白名单+还原+回读校验）、[aurorack](https://gitee.com/pzzzpsjjw/aurorack)（node 26/182 双通道探测）
- 机制旁证：[OPPO 专利 CN115657870A](https://patents.google.com/patent/CN115657870A/zh)（按前台应用+场景列表决定 TP 采样率）