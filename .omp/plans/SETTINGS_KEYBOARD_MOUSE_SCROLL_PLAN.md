# Settings: Keyboard/Mouse pages + scroll wheel multiplier

## Context

Two user requests:
1. Add **Keyboard** and **Mouse** categories to the settings panel and move the keyboard/mouse settings currently buried in `AdvancedView` into them.
2. New mouse feature: **scroll wheel multiplier** — scales the amount each incoming MWB wheel event (from the Windows machine) scrolls on the Mac. Purely affects remote-injected scrolling; Mac-local mouse/trackpad scrolling untouched.

## Current state (verified)

- `MWBClient/UI/Settings/SettingsWindow.swift` — `SettingsPage` enum (`connection`, `layout`, `clipboard`, `permissions`, `advanced`) drives a `NavigationSplitView` sidebar + detail switch.
- `MWBClient/UI/Settings/AdvancedView.swift` — contains the `Section("Keyboard")` (swapOptionCommand) and `Section("Advanced Mouse Settings")` (moveMouseRelatively, blockMouseAtCorners, hideMouseAtScreenEdge, disableEasyMouseInFullscreen, invertRemoteScroll) that must move out. Remaining sections (Machine, Security & Power, About, Developer) stay.
- `MWBClient/Persistence/SettingsStore.swift` — `SettingsKey`/`SettingsDefault`/`CachedSettings` + `@MainActor @Observable SettingsStore`; hot-path settings are mirrored into `CachedSettings` (nonisolated(unsafe) statics) in `didSet`.
- `MWBClient/Input/InputInjection.swift:366` — `static func scrollPixels(delta: Int32, invert: Bool) -> Int32` computes `(delta / 120) * 3` pixels per notch; called from `handleScrollWheel(delta:at:horizontal:)` (line ~380) which handles both vertical (`.mouseWheel`) and horizontal (`.mouseHWheel`) remote scroll.
- `MWBClientTests/InputInjectionTests.swift:222` — `testScrollPixelConversion()` calls `InputInjection.scrollPixels(delta:invert:)`.
- `project.yml` sources are directory-based (`- path: MWBClient`), so new files only need `make generate` (xcodegen).
- PowerToys reference sends wheel deltas as multiples of `WHEEL_DELTA` (120) per notch; the 3-pixels-per-notch base already matches the Windows default of 3 lines per notch. The multiplier is a client-only feature (no PowerToys equivalent needed for interop).

## Approach

### Step 1 — `SettingsStore`: add `scrollMultiplier`

File: `MWBClient/Persistence/SettingsStore.swift`

1. `SettingsKey`: add `static let scrollMultiplier = "settings.scrollMultiplier"`.
2. `SettingsDefault`: add `static let scrollMultiplier: Double = 1.0`.
3. `CachedSettings`: add `nonisolated(unsafe) static var scrollMultiplier: Double` initialized with `UserDefaults.standard.object(forKey: "settings.scrollMultiplier") as? Double ?? 1.0` — **not** `double(forKey:)` (returns 0.0 when unset, which would zero out scrolling).
4. `SettingsStore`: add stored property
   ```swift
   /// Multiplier applied to scroll events injected from the remote machine.
   /// 1.0 = Windows default (3 lines per wheel notch). Mac-local scrolling unaffected.
   var scrollMultiplier: Double {
       didSet {
           UserDefaults.standard.set(scrollMultiplier, forKey: SettingsKey.scrollMultiplier)
           CachedSettings.scrollMultiplier = scrollMultiplier
       }
   }
   ```
   In `init()`: `self.scrollMultiplier = defaults.object(forKey: SettingsKey.scrollMultiplier) as? Double ?? SettingsDefault.scrollMultiplier`.
   In `resetToDefaults()`: `scrollMultiplier = SettingsDefault.scrollMultiplier`.
5. No clamp on write — the UI Slider bounds are the only clamp needed.

### Step 2 — `InputInjection`: apply the multiplier

File: `MWBClient/Input/InputInjection.swift`

1. Change signature:
   ```swift
   static func scrollPixels(delta: Int32, invert: Bool, multiplier: Double) -> Int32 {
       var pixels = Int32((CGFloat(delta) / 120.0) * 3.0 * CGFloat(multiplier))
       if invert { pixels = -pixels }
       return pixels
   }
   ```
   (Multiplier scales before inversion so invert keeps meaning "flip direction".)
2. Update the only caller, `handleScrollWheel` (~line 380):
   `let pixelDelta = Self.scrollPixels(delta: delta, invert: CachedSettings.invertRemoteScroll, multiplier: CachedSettings.scrollMultiplier)`. Both vertical and horizontal remote scroll get the multiplier (same call site).
3. Do **not** touch `InputCapture.swift` — the multiplier is inbound-only (Windows→Mac); Mac→Windows wheel capture is unchanged.

### Step 3 — New settings pages

Create two new files (patterns copied verbatim from existing views — `@Environment(SettingsStore.self)`, `Form`, `.formStyle(.grouped)`, same caption styling):

**`MWBClient/UI/Settings/KeyboardView.swift`** — contains the "Keyboard" section moved verbatim from `AdvancedView` (Swap Option and Command toggle + caption). `navigationTitle("Keyboard")`.

**`MWBClient/UI/Settings/MouseView.swift`** — contains:
- The five mouse toggles moved verbatim from `AdvancedView`'s "Advanced Mouse Settings" section (moveMouseRelatively, blockMouseAtCorners, hideMouseAtScreenEdge, disableEasyMouseInFullscreen, invertRemoteScroll), each keeping its existing Toggle + caption VStack.
- New scroll multiplier control at the end of the section:
  ```swift
  VStack(alignment: .leading, spacing: 4) {
      HStack {
          Text("Scroll wheel multiplier")
          Spacer()
          Text("\(settings.scrollMultiplier, format: .number.precision(.fractionLength(1)))×")
              .foregroundStyle(.secondary)
              .monospacedDigit()
      }
      Slider(value: $settings.scrollMultiplier, in: 0.25...4.0, step: 0.25)
      Text("Scales how far each scroll wheel event from the Windows machine scrolls. Does not affect your Mac's own mouse and trackpad scrolling.")
          .font(.caption)
          .foregroundStyle(.secondary)
  }
  ```
- `navigationTitle("Mouse")`.

**`MWBClient/UI/Settings/AdvancedView.swift`** — delete the "Keyboard" and "Advanced Mouse Settings" sections entirely (clean cutover, no duplicates). Keep Machine / Security & Power / About / Developer.

### Step 4 — Wire the pages into `SettingsWindow`

File: `MWBClient/UI/Settings/SettingsWindow.swift`

1. `enum SettingsPage`: add `case keyboard` and `case mouse`.
2. Sidebar list, inserted between "Screen Layout" and "Clipboard":
   ```swift
   Label("Keyboard", systemImage: "keyboard")
     .tag(SettingsPage.keyboard)
   Label("Mouse", systemImage: "computermouse")
     .tag(SettingsPage.mouse)
   ```
3. Detail switch: `case .keyboard: KeyboardView()` and `case .mouse: MouseView()`.

### Step 5 — Regenerate project

`make generate` (never hand-edit `MWBClient.xcodeproj`).

### Step 6 — Update tests

File: `MWBClientTests/InputInjectionTests.swift`

`testScrollPixelConversion()` currently calls `scrollPixels(delta:invert:)` — update all calls to the new 3-parameter form with `multiplier: 1.0` (assertions unchanged: 120→3, -120→-3, 240→6, 0→0, invert flips sign), and add multiplier cases:
```swift
XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: false, multiplier: 2.0), 6)
XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: false, multiplier: 0.5), 1)   // 1.5 truncates to 1 via Int32 conversion
XCTAssertEqual(InputInjection.scrollPixels(delta: -120, invert: true, multiplier: 3.0), 9)
XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: false, multiplier: 0.25), 0)  // 0.75 truncates to 0
```

## Critical files & anchors

- `MWBClient/UI/Settings/AdvancedView.swift` — lines 24–80: the two sections to cut.
- `MWBClient/UI/Settings/SettingsWindow.swift` — `SettingsPage` enum + sidebar list + detail switch.
- `MWBClient/Persistence/SettingsStore.swift` — `SettingsKey`/`SettingsDefault`/`CachedSettings`/`SettingsStore` init + `resetToDefaults`.
- `MWBClient/Input/InputInjection.swift` — `scrollPixels` (~line 366) and `handleScrollWheel` (~line 380).
- `MWBClientTests/InputInjectionTests.swift` — `testScrollPixelConversion` (~line 222).

## Verification

1. `make generate` — regenerates project with the two new files.
2. `make build` — compiles (catches signature drift of `scrollPixels` callers; `handleScrollWheel` is the only caller besides tests).
3. Unit tests: `xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS' -derivedDataPath build/TestDerivedData` — all existing suites plus updated `testScrollPixelConversion` pass.
4. Manual UI smoke (needs `make run`; requires a real display):
   - Settings window sidebar shows Connection / Screen Layout / Keyboard / Mouse / Clipboard / Permissions / Advanced in that order.
   - Keyboard page shows only "Swap Option and Command"; Mouse page shows the five moved toggles + scroll multiplier slider; Advanced page no longer shows either section.
   - Slide multiplier to 4.0×, quit & relaunch → slider still 4.0× (persistence), `defaults read com.mwb.client settings.scrollMultiplier` prints `4`.
   - If a Windows MWB host is available: one wheel notch with multiplier 2× scrolls visibly twice as far as 1×; Mac trackpad scrolling is unchanged in both cases. If no host is available, the unit tests in step 3 cover the conversion math and the persistence check covers the wiring.
5. Reset check: trigger `resetToDefaults()` (or delete the defaults key) → multiplier returns to 1.0.

## Assumptions & contingencies

- Multiplier range fixed at 0.25–4.0 with 0.25 steps, default 1.0 (UI Slider bounds are the only clamp). If finer/coarser range is wanted later, it's a one-line change in `MouseView`.
- Multiplier applies to horizontal remote scroll as well (same code path) — symmetric and expected.
- Sub-notch fractional results truncate toward zero via `Int32(...)` conversion (pre-existing behavior; e.g. 0.5× on one notch = 1 pixel, 0.25× = 0). Acceptable: minimum useful multiplier is effectively 0.5 for single-notch events, larger deltas accumulate correctly.
- PowerToys reference already consulted at `/Users/edgeneko/Workspace/PowerToys/src/modules/MouseWithoutBorders` (wheel deltas are multiples of 120; no client-side multiplier exists there — this is a Mac-client-only addition, so no protocol impact).
