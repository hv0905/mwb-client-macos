import Carbon.HIToolbox
import Foundation

/// Queries and switches keyboard input sources (Text Input Source Services).
///
/// Used by ``InputInjection`` to implement the macOS "short Caps Lock press
/// switches Chinese/English" behavior: a spike proved that `CGEventPost`
/// cannot drive the system's native Caps Lock tap/hold state machine (it
/// lives in WindowServer/HID, not the CGEvent layer), so the client must
/// classify press duration itself and switch the input source via TIS.
enum InputSourceSwitcher {
    /// The input source ID of macOS's built-in ASCII layout, preferred
    /// English target when toggling away from a Chinese IME.
    private static let abcSourceID = "com.apple.keylayout.ABC"

    /// The most recent Chinese input source seen active, so toggling back
    /// restores the user's actual IME instead of an arbitrary one.
    nonisolated(unsafe) private static var lastCJKSourceID: String?

    // MARK: - Property helpers

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID) as? String
    }

    /// The primary language tag (e.g. "zh-Hans", "en") of the source.
    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] else {
            return nil
        }
        return languages.first
    }

    private static func isEnabled(_ source: TISInputSource) -> Bool {
        (property(source, kTISPropertyInputSourceIsEnabled) as? Bool) ?? false
    }

    private static func isCJK(_ source: TISInputSource) -> Bool {
        primaryLanguage(source)?.hasPrefix("zh") ?? false
    }

    // MARK: - Queries

    /// All keyboard input sources the user has enabled.
    private static func enabledSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    /// True when the user has a Chinese input source enabled, i.e. the
    /// "short Caps Lock press switches language" behavior applies.
    static func cjkInputSourceEnabled() -> Bool {
        enabledSources().contains { isCJK($0) }
    }

    // MARK: - Switching

    /// Toggles between the current Chinese input source and ASCII (ABC).
    ///
    /// Mirrors the native "Use Caps Lock key to switch ABC" behavior at the
    /// input-source level: when a Chinese IME is active, selects ABC; when
    /// an English layout is active, reselects the last-used Chinese source
    /// (or the first enabled one). Must be called on the main thread
    /// (TIS doc: TISSelectInputSource should be called from the main thread).
    static func toggleCJKAndASCII() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            mwbWarning(MWBLog.input, "Input source toggle: no current input source")
            return
        }

        if isCJK(current) {
            lastCJKSourceID = sourceID(current)
            if let target = asciiTarget() {
                select(target)
            } else {
                mwbWarning(MWBLog.input, "Input source toggle: no ASCII input source found")
            }
            return
        }

        guard let target = cjkTarget() else {
            mwbWarning(MWBLog.input, "Input source toggle: no Chinese input source found")
            return
        }
        select(target)
    }

    /// The ABC layout, or the first enabled English-layout source.
    private static func asciiTarget() -> TISInputSource? {
        let sources = enabledSources()
        if let abc = sources.first(where: { sourceID($0) == abcSourceID }) {
            return abc
        }
        return sources.first { primaryLanguage($0)?.hasPrefix("en") ?? false }
    }

    /// The last-used Chinese source when known, otherwise the first enabled one.
    private static func cjkTarget() -> TISInputSource? {
        let sources = enabledSources()
        if let lastID = lastCJKSourceID,
           let remembered = sources.first(where: { sourceID($0) == lastID && isEnabled($0) }) {
            return remembered
        }
        return sources.first { isCJK($0) }
    }

    private static func select(_ source: TISInputSource) {
        let id = sourceID(source) ?? "?"
        let status = TISSelectInputSource(source)
        if status != noErr {
            mwbWarning(MWBLog.input, "Input source toggle: selecting \(id) failed (OSStatus \(status))")
        } else {
            mwbDebug(MWBLog.input, "Input source toggled to \(id)")
        }
    }
}
