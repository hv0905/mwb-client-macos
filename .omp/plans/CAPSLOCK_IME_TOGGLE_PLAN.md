# Caps Lock 中文 IME 短按切语言 / 长按切大小写修复

Slug: `capslock-ime-toggle`

## Context

Windows 端（PowerToys MWB `InputSimulation.SendKey`）把低层钩子捕获的 VK_CAPITAL (0x14) 的 key-down/key-up 原样转发，长按期间伴随 autorepeat 重复 key-down。macOS 客户端当前处理（`MWBClient/Input/InputInjection.swift` `injectKeyboard` caps 分支，~425 行）：key-down 翻转本地 `capsLockOn` 并 post 单个 `.flagsChanged`，**key-up 直接吞掉**。结果：macOS 看不到完整按下-抬起，短按无法触发原生中英切换，短按还会污染大小写状态。

目标：复刻原生语义——中文 IME 下短按切输入法、长按切大写锁定、纯英文环境短按切大小写。**首选方案是零特殊状态**：把 Caps Lock 转发为原生形态的 down/up 事件对，让 macOS 自己的 tap/hold 状态机分类；仅当注入事件被证明驱动不了原生状态机时，才用本地计时状态机 + TIS 切换兜底。

## Approach

### Step 0 — Spike：注入事件能否驱动原生 caps tap/hold 状态机（先行，决定 Branch A/B）

前置条件：本机启用简体拼音 + ABC，物理短按 Caps Lock 能切换中/英；测试宿主有 Accessibility 信任（沿用 `testStaleButtonDownInjectsMissingUpAndCarriesEventNumber` 的 `AXIsProcessTrusted()` / tap 不可用 `XCTSkip` 模式）。任一条件不满足 → 直接走 **Branch B**，跳过本步。

新建临时测试 `MWBClientTests/CapsLockSpikeTests.swift`（分支决定后删除，结论写进 caps 处理代码注释）：

1. **记录原生事件流（ground truth）**：`import Carbon.HIToolbox`。用会话级 CGEventTap（复用 `InputInjectionTests.swift` 底部 `InjectedEventTap` 的 bridge 模式，过滤 keycode 0x39）观察物理键盘：拼音激活下短按 Caps、长按 Caps、仅 ABC 下短按 Caps，各自产生的事件序列（type/flags）。人工按键，测试内 `waitForObservations` 采集。
2. **注入回放**：post 以下变体到 `.cghidEventTap`，拼音激活状态，每变体后 sleep ~300ms 读 `TISCopyCurrentKeyboardInputSource()` 的 `kTISPropertyInputSourceID`，结束用 `TISSelectInputSource` 还原：
   - V1：`flagsChanged`(keycode 0x39, keyDown true) + `flagsChanged`(keycode 0x39, keyDown false)，构造方式同 `postFlagsChanged`（`CGEvent(keyboardEventSource:virtualKey:keyDown:)` 后设 `type = .flagsChanged`、flags = 当前 `currentModifierFlags` 且不翻转 alphaShift）。
   - V2：普通 `keyDown` + `keyUp`（keycode 0x39，不改 type）。
   - V3：步骤 1 记录到的原生序列逐事件复刻。

判定规则（机械执行）：任一变体使输入源 ID 变化 → **Branch A**（采用生效变体，优先 V1 > V3 > V2）；全部不变 → **Branch B**。

### Branch A — 纯事件转发（spike 成功时；首选）

文件：`MWBClient/Input/InputInjection.swift`。让 macOS 完全接管 tap/hold 分类与 alphaShift 状态，本地不维护 caps 计时/切换。

1. **删除** `private var capsLockOn` 与 toggle 逻辑。`injectKeyboard` 的 caps 分支改为 `handleCapsLock(isKeyUp:)`：
   - 仅做 down/up 配对与 autorepeat 去重（Windows 长按会发重复 key-down，而 macOS 硬件 Caps 不重复）：新增 `private var capsKeyDown = false`；down 时若已 `capsKeyDown` 则忽略，否则置 true 并 post spike 胜出变体的 down 事件；up 时若非 `capsKeyDown` 忽略（孤儿 up），否则置 false 并 post 对应 up 事件。
   - down/up 事件 flags = `currentModifierFlags`，**不含** alphaShift 翻转（原生短按时 flags 不变，分类由系统完成）。
2. **alphaShift 改读系统状态**：新增 `var systemAlphaShift: () -> Bool = { MWBEventSource.shared.flags.contains(.maskAlphaShift) }`；`modifierFlags(held:capsLockOn:)` 签名改为 `modifierFlags(held:systemAlphaShift: Bool)`，`keyEventFlags`/`currentModifierFlags` 同步改，调用点全部更新（全仓 `grep capsLockOn` 应只剩零处）。macOS 原生 toggle 后系统 flags 即正确，注入按键自然携带大写状态。
3. `reset()` 不再做 caps 相关清理（无计时状态）；`releaseAllKeys()` 原样保留（本就不碰 caps）。
4. 已知限制写注释：Caps Lock LED 无法由注入点亮。
5. 测试（`MWBClientTests/InputInjectionTests.swift`）：
   - **删除** `testCapsLockTogglesPerKeyDown`；`testReleaseAllKeysClearsState` 去掉 caps 断言（仅验证 modifiers 释放）。
   - 新增：autorepeat 去重（down, down, up → 状态归 false）；孤儿 up 忽略；`keyEventFlags` 在 `systemAlphaShift: true` 时含 `.maskAlphaShift`（用注入闭包置 true，不依赖系统环境）。

### Branch B — 本地状态机 + TIS 切换（spike 失败或环境不可用时）

文件：`MWBClient/Input/InputInjection.swift` + 新建 `MWBClient/Input/InputSourceSwitcher.swift`（`import Carbon.HIToolbox`，系统框架无需改 project.yml 链接；新增文件后 `make generate`）。

1. 新增可注入时钟（沿用 `screenBoundsProvider` 注入闭包约定）：`var nowProvider: () -> ContinuousClock.Instant = { ContinuousClock().now }`；常量 `static let capsLockHoldThreshold: Duration = .seconds(1)`。
2. caps 分支改为 `handleCapsLock(isKeyUp:)` 状态机：
   - **down**：`capsKeyDown` 已 true → 忽略（autorepeat）；否则 `capsKeyDown = true`、`capsKeyDownInstant = nowProvider()`，不 post 事件。
   - **up**：`capsKeyDown` 为 false → 忽略；否则算 `duration`，清状态后分类：
     - `duration >= threshold`（长按）：`capsLockOn.toggle()`，`postFlagsChanged(keycode: 0x39, keyDown: true)`（注释说明：注入无法驱动 LED/硬件 hold，单 transition 是已知偏差）。
     - `duration < threshold`（短按）：
       - `cjkInputSourceEnabled()` 为 true → 语言切换，`capsLockOn` 不变，`DispatchQueue.main.async { self.inputSourceToggle() }`，不 post 键盘事件。
       - 否则 → `capsLockOn.toggle()` 并 `postFlagsChanged(keycode: 0x39, keyDown: true)`（纯英文短按 = 大小写切换）。
   - 可注入开关（默认真实实现）：`var cjkInputSourceEnabled: () -> Bool = { InputSourceSwitcher.cjkInputSourceEnabled() }`、`var inputSourceToggle: () -> Void = { InputSourceSwitcher.toggleCJKAndASCII() }`。
3. `InputSourceSwitcher`：
   - `static func cjkInputSourceEnabled() -> Bool`：`TISCreateInputSourceList([kTISPropertyInputSourceIsEnabled: true], false)` 中任一源的 `kTISPropertyInputSourceLanguages` 首语言前缀 `"zh"` 即 true。
   - `static func toggleCJKAndASCII()`（主线程调用）：当前源首语言前缀 `"zh"` → 选 ASCII 源（优先 `kTISPropertyInputSourceID == "com.apple.keylayout.ABC"`，否则首个首语言 `"en"` 源）；否则选中文源（优先静态记忆 `lastCJKSourceID`——每次当前为中文源时记录——否则首个 `"zh"` 源）；`TISSelectInputSource`；未找到记 `mwbWarning(MWBLog.input, ...)` 不切换。
4. `reset()`：清 `capsKeyDown`/`capsKeyDownInstant`，保留 `capsLockOn`；`releaseAllKeys()` 不变。
5. 测试：同 Branch A 的删除/修改项，另新增（fake `nowProvider` + 注入计数闭包）：短按+CJK → `capsLockOn` 不变且 toggle 恰好一次；短按+非 CJK → `capsLockOn` 翻转；长按（down → 前进 1.1s → up）→ 翻转恰好一次，hold 中重复 down 不影响计时；孤儿 up / `reset()` 后 up → 状态不变。`testReleaseAllKeysClearsState` 的 caps setup 改为长按序列。

### Step 4 — 验证（两分支共用）

1. `make generate`（仅 Branch B 有新文件）→ `make build`。
2. `xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`。
3. 新行为证明：spike（删除前）记录注入后输入源 ID 变化 = 短按切语言可行；单测证明配对/去重/分类逻辑。
4. 手工端到端冒烟（需真实 Windows PowerToys 发端；不可用时报告此限制）：Mac 拼音激活，光标切到 Mac 后——Windows 键盘短按 Caps → 中/英切换；按住 ≥1s 松开 → 后续字母大写；仅 ABC 配置下短按 → 大小写切换。观察：菜单栏输入法指示 + 文本编辑器输入结果。

## Critical files & anchors

- `MWBClient/Input/InputInjection.swift` — `injectKeyboard` caps 分支（~425 行）、`postFlagsChanged`、`modifierFlags`/`keyEventFlags`/`currentModifierFlags`、`reset()`。
- `MWBClientTests/InputInjectionTests.swift` — 删旧 caps 测试、加新配对/分类测试（参考 `screenBoundsProvider` 注入闭包模式；tap bridge 在文件底部 `InjectedEventTap`）。
- `MWBClientTests/CapsLockSpikeTests.swift` — 临时 spike，分支决定后删除。
- `MWBClient/Input/InputSourceSwitcher.swift` — 仅 Branch B 新建。
- `Makefile` — `make generate` / `make build`（无测试 target，用上方 xcodebuild 命令）。

## Assumptions & contingencies

- 长按阈值（仅 Branch B）取 1.0s，近似原生 hold 延迟；手感偏差只调 `capsLockHoldThreshold`。
- Branch B 的 TIS 切换是输入源级（ABC↔拼音）而非 IME 内部中/英模式；打字效果等价，接受。
- Branch A 下若 spike 通过但真实 Windows 链路冒烟发现 autorepeat 干扰（系统把重复 down 误判），处理已内置：down 去重。
- spike 环境不可用（无 Accessibility 信任/无中文输入法）→ 直接 Branch B。
