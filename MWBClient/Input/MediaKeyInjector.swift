import AppKit
import CoreGraphics

/// Translates Windows media-key VK codes into native macOS media actions.
///
/// macOS has no CG keycode for volume/playback media keys. Native media
/// handlers listen for `NSEventType.systemDefined` events with subtype 8
/// (`NSEventSubtypeMediaKey` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS`) and an
/// `NX_KEYTYPE_*` key type from IOKit's `ev_keymap.h`, so this injector posts
/// that event class instead of going through ``KeyCodeMapper``.
enum MediaKeyInjector {

    /// Windows media-key VK codes that this injector consumes.
    enum MediaKey: UInt16 {
        case volumeMute = 0xAD
        case volumeDown = 0xAE
        case volumeUp = 0xAF
        case nextTrack = 0xB0
        case previousTrack = 0xB1
        case stop = 0xB2
        case playPause = 0xB3

        /// The macOS `NX_KEYTYPE_*` value from IOKit `ev_keymap.h`.
        ///
        /// `VK_MEDIA_STOP` has no macOS counterpart (`NX_KEYTYPE_STOP` does
        /// not exist), so it maps to `nil` and is consumed without an action.
        var nxKey: UInt32? {
            switch self {
            case .volumeUp: return 0     // NX_KEYTYPE_SOUND_UP
            case .volumeDown: return 1   // NX_KEYTYPE_SOUND_DOWN
            case .volumeMute: return 7   // NX_KEYTYPE_MUTE
            case .playPause: return 16   // NX_KEYTYPE_PLAY
            case .nextTrack: return 17   // NX_KEYTYPE_NEXT
            case .previousTrack: return 18 // NX_KEYTYPE_PREVIOUS
            case .stop: return nil
            }
        }
    }

    /// `NSEventSubtypeMediaKey` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    private static let mediaKeySubtype: Int16 = 8

    /// `NX_KEYSTATE_UP`/`DOWN` are reported in the low bits of `data1`:
    /// 0xA for a press, 0xB for a release.
    private static let downState: UInt32 = 0xA
    private static let upState: UInt32 = 0xB

    /// Pure, testable encoding of the `data1` field for a media-key event:
    /// the NX key type in the high 16 bits, the key state in bits 8-11.
    ///
    /// This is the encoding macOS itself uses for hardware media keys
    /// (see `IOKit/hidsystem/ev_keymap.h` and `HIDPostEvent` samples).
    static func data1(for nxKey: UInt32, isDown: Bool) -> Int {
        let state: UInt32 = isDown ? downState : upState
        return Int((nxKey << 16) | (state << 8))
    }

    /// Dedicated source for posted media events. `CGEventSource` is not
    /// Sendable; it is created once and only read here, so unchecked sharing
    /// is safe. HIDSystemState is used because media keys originate from the
    /// HID system, and native handlers expect that source state.
    nonisolated(unsafe) private static let eventSource = CGEventSource(stateID: .hidSystemState)

    /// Injects a Windows media-key packet as a native macOS media action.
    ///
    /// Returns `false` when the VK code is not a media key, so the caller can
    /// fall through to ordinary keycode injection. For media keys, returns
    /// `true` (the packet is fully consumed): one Windows key-down posts a
    /// complete down+up pair so a single press acts exactly once, while
    /// Windows autorepeat key-downs keep acting; the forwarded Windows key-up
    /// is consumed so the action is not repeated on release.
    static func inject(_ data: KeyboardData) -> Bool {
        guard let mediaKey = MediaKey(rawValue: data.vkCode) else {
            return false
        }

        if data.isKeyUp {
            // The down event already performed the full press; consuming the
            // release keeps the action from being applied twice.
            return true
        }

        guard let nxKey = mediaKey.nxKey else {
            mwbDebug(MWBLog.input, "VK_MEDIA_STOP has no macOS media-key counterpart; ignored")
            return true
        }

        postSystemDefinedMediaKey(nxKey, isDown: true)
        postSystemDefinedMediaKey(nxKey, isDown: false)
        return true
    }

    /// Posts a single systemDefined media-key event (down or up) with the
    /// standard `NSEventSubtypeMediaKey` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS`
    /// layout: `data1` encodes key type + state, `data2` is -1.
    private static func postSystemDefinedMediaKey(_ nxKey: UInt32, isDown: Bool) {
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
        ), let cgEvent = nsEvent.cgEvent else {
            mwbError(MWBLog.input, "Failed to create media key CGEvent for NX key \(nxKey)")
            return
        }

        cgEvent.setSource(eventSource)
        cgEvent.post(tap: .cghidEventTap)
    }
}
