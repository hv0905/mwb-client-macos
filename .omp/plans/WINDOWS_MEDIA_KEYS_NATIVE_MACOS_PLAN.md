# Windows media keys → native macOS media actions

## Context

The macOS client receives Windows keyboard packets through `InputInjection.injectKeyboard`, but media-key VK codes (volume, playback) are absent from `KeyCodeMapper`, so they are logged as “unmapped VK code” and dropped. The goal is to make Windows-originated media keys perform the native macOS media actions: volume up/down/mute, play/pause, next track, previous track. macOS media keys are not ordinary CG keycodes; native media handlers listen for `NSEventType.systemDefined` events with subtype 8 (`NSEventSubtypeMediaKey` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS`), so the client must post that event class. Reverse-direction Mac→Windows forwarding is unchanged.

## Approach

1. Add `MWBClient/Input/MediaKeyInjector.swift` (no equivalent exists in the repo). Import `AppKit` and `CoreGraphics`.
   - Define an internal enum:
     ```swift
     enum MediaKey: UInt16 {
         case volumeMute = 0xAD
         case volumeDown = 0xAE
         case volumeUp = 0xAF
         case nextTrack = 0xB0
         case previousTrack = 0xB1
         case stop = 0xB2
         case playPause = 0xB3

         var nxKey: UInt32? {
             switch self {
             case .volumeMute: return 7    // NX_KEYTYPE_MUTE
             case .volumeDown: return 1    // NX_KEYTYPE_SOUND_DOWN
             case .volumeUp: return 0       // NX_KEYTYPE_SOUND_UP
             case .nextTrack: return 17     // NX_KEYTYPE_NEXT
             case .previousTrack: return 18 // NX_KEYTYPE_PREVIOUS
             case .playPause: return 16     // NX_KEYTYPE_PLAY
             case .stop: return nil         // no macOS NX key type
             }
         }
     }
     ```
   - Define private constants:
     - `mediaKeySubtype: Int16 = 8` (`NSEventSubtypeMediaKey` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS`).
     - `downState: UInt32 = 0xA`, `upState: UInt32 = 0xB`.
   - Add a pure, testable helper:
     ```swift
     static func data1(for nxKey: UInt32, isDown: Bool) -> Int
     ```
     It returns `(nxKey << 16) | ((isDown ? downState : upState) << 8)`.
   - Add a dedicated source for media events:
     ```swift
     nonisolated(unsafe) private static let eventSource = CGEventSource(stateID: .hidSystemState)
     ```
     Use `.hidSystemState` (not the existing `.combinedSessionState` mouse/keyboard source) because media key events originate from the HID system and the known-good posting pattern uses HIDSystemState.
   - Implement:
     ```swift
     static func inject(_ data: KeyboardData) -> Bool
     ```
     Behavior:
     - `MediaKey(rawValue: data.vkCode)` nil → return `false` (not a media key).
     - `data.isKeyUp` → return `true` (consume the release; no action).
     - `mediaKey.nxKey == nil` (`VK_MEDIA_STOP`) → log `mwbDebug(MWBLog.input, "VK_MEDIA_STOP has no macOS media-key counterpart; ignored")` and return `true`.
     - Otherwise post one complete media-key press (down + up) and return `true`.
   - Posting helper:
     ```swift
     private static func postSystemDefinedMediaKey(_ nxKey: UInt32, isDown: Bool)
     ```
     Build:
     ```swift
     let state: UInt32 = isDown ? downState : upState
     let flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8))
     let data1 = Self.data1(for: nxKey, isDown: isDown)

     guard let nsEvent = NSEvent.otherEvent(
         with: .systemDefined,
         location: .zero,
         modifierFlags: flags,
         timestamp: 0,
         windowNumber: 0,
         context: nil,
         subtype: mediaKeySubtype,
         data1: data1,
         data2: -1
     ), let cgEvent = nsEvent.cgEvent else { ... }
     ```
     On failure, log `mwbError(MWBLog.input, "Failed to create media key CGEvent for NX key \(nxKey)")` and return.
     On success, call:
     ```swift
     cgEvent.setSource(eventSource)
     cgEvent.post(tap: .cghidEventTap)
     ```
   - Key-downs post a down+up pair; the forwarded Windows key-up is consumed. This keeps a single Windows press from applying twice while still allowing Windows autorepeat key-downs to act repeatedly.

2. Modify `MWBClient/Input/InputInjection.swift`, in `injectKeyboard(_:swapOptionCommand:)`, before the `guard var keycode = KeyCodeMapper.vkToMacOS(...)` line and before applying `swapOptionCommand`:
   ```swift
   if MediaKeyInjector.inject(data) {
       return
   }
   ```
   The existing call site is already `@MainActor` (`AppCoordinator.handleRemoteKeyboard`), so creating the AppKit `NSEvent` on this path is safe.
   Update the method’s doc comment to state that media-key VK codes are consumed by `MediaKeyInjector` and posted as native system-defined media key events, not as CG keycodes. Do not consult `data.isExtended`; media keys are identified by VK code alone.

3. Add `MWBClientTests/MediaKeyInjectorTests.swift`.
   - `@testable import MWBClient`; import `ApplicationServices`, `AppKit`, `CoreGraphics`, `XCTest`.
   - Pure mapping tests:
     - Every `MediaKey` raw value resolves to the expected case.
     - `nxKey` values are exactly `0, 1, 7, 16, 17, 18` for sound-up, sound-down, mute, play, next, previous.
     - `MediaKey.stop.nxKey == nil`.
   - Data encoding tests:
     - `MediaKeyInjector.data1(for:isDown:)` for down is `(nxKey << 16) | 0xA00`.
     - `MediaKeyInjector.data1(for:isDown:)` for up is `(nxKey << 16) | 0xB00`.
     - Concrete expected values: volume-up down `0x0A00`, up `0x0B00`; play down `0x100A00`, up `0x100B00`; next down `0x110A00`, up `0x110B00`.
   - End-to-end posting test (skip with `XCTSkip` when `AXIsProcessTrusted()` is false or the tap cannot be created):
     - Add a private `MediaKeyEventTap` modeled on the existing `InjectedEventTap` bridge in `MWBClientTests/InputInjectionTests.swift`, listening for `CGEventType(rawValue: NSEvent.EventType.systemDefined.rawValue)` (14) at `.cgSessionEventTap`.
     - In the tap callback, convert the `CGEvent` back with `NSEvent(cgEvent:)`, and keep events with `subtype == 8` and `UInt32(truncatingIfNeeded: nsEvent.data1 >> 16) == expectedNXKey`; record `type`, `subtype`, `data1`, `data2`, and event number. Prefer an active (suppressing) tap; fall back to listen-only.
     - Call:
       ```swift
       let injection = InputInjection()
       injection.injectKeyboard(KeyboardData(vkCode: 0xAF, flags: 0)) // VK_VOLUME_UP
       ```
     - Wait for exactly two observations. Assert the `data1` values are `[0x0A00, 0x0B00]`, `data2 == -1`, `subtype == 8`, and the event type is system-defined (raw 14). Suppressing the tap is preferred so the volume does not actually change.
   - Key-up test (same tap, same skip conditions):
     - Inject `KeyboardData(vkCode: 0xAF, flags: LLKHFFlag.up.rawValue)`.
     - Wait a short interval and assert zero matching observations, proving the remote key-up does not post a second media action.

4. Update `docs/protocol/04. input sync.md`, under **Keyboard Sync**, with one short note:
   - Windows media VK codes `0xAD–0xB3` arrive as ordinary keyboard packets.
   - The macOS client maps volume/playback keys to `NSEventType.systemDefined` subtype 8 events using the `NX_KEYTYPE_*` values above.
   - `VK_MEDIA_STOP` has no macOS counterpart and is consumed without an action.
   - Synthetic F-key keycodes are deliberately not used; media apps listen for the system-defined event class.

5. Regenerate and verify.
   - Run `make generate` (new files are picked up from `MWBClient` and `MWBClientTests`; never edit `MWBClient.xcodeproj` manually).
   - Build with `make build`.
   - Run tests with:
     ```sh
     xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS' -derivedDataPath build/TestDerivedData
     ```
   - Manual smoke (requires a real Windows MWB host and a real Mac session):
     1. `make run`.
     2. Cross to the Windows machine, then press volume up/down/mute: the Mac’s native volume overlay appears and volume changes.
     3. Press play/pause, next track, previous track with a media app active: the app performs the native media action.
     4. Press stop: nothing happens (intentional; no macOS media key exists).

## Critical files & anchors

- `MWBClient/Input/InputInjection.swift` — `injectKeyboard(_:swapOptionCommand:)`; insert the `MediaKeyInjector.inject(data)` early return before keycode lookup and swap.
- `MWBClient/Input/MediaKeyInjector.swift` — new file; owns the VK → NX key mapping, systemDefined event construction, and HID event source.
- `MWBClientTests/MediaKeyInjectorTests.swift` — new file; mapping, data encoding, and event-tap posting tests.
- `MWBClientTests/InputInjectionTests.swift` — reference for the `InjectedEventTap` bridge pattern used by the new media-key tap.
- `docs/protocol/04. input sync.md` — add the media-key behavior note under Keyboard Sync.

## Verification

- Automated: the new mapping and `data1` tests prove the exact wire-level encoding; the event-tap test proves `InputInjection.injectKeyboard` produces a down+up systemDefined media key pair and that key-up posts nothing.
- Build/test commands:
  ```sh
  make generate
  make build
  xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS' -derivedDataPath build/TestDerivedData
  ```
- End-to-end manual check: with a Windows MWB host connected, pressing the Windows volume and playback keys on the Mac must drive the native macOS volume overlay and media actions exactly once per Windows key-down; `VK_MEDIA_STOP` must be a no-op.

## Assumptions & contingencies

- Scope is the standard Windows media VK range `0xAD–0xB3`. Launch keys (`0xB5 VK_LAUNCH_MEDIA_SELECT`, mail/app launch) are intentionally not handled.
- `VK_MEDIA_STOP` is consumed and ignored because macOS has no `NX_KEYTYPE_STOP`; if a future macOS SDK adds one, extend `MediaKey.nxKey` rather than removing the stop case.
- If posting systemDefined events from the app process proves blocked in some environment, first try switching the media event source to `CGEventSource(stateID: .combinedSessionState)` before considering any `MediaRemote` private-framework fallback; the systemDefined path is the public, native mechanism and must remain the default.
- If the posted down/up pair is dropped in the compiled app (the documented `CGEventPost` cold-start issue), add a 1 ms pause between the down and up posts; do not replace the systemDefined path with synthetic F-key keycodes.
