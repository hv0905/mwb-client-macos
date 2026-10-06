import ApplicationServices
import AppKit
import CoreGraphics
import XCTest
@testable import MWBClient

/// Verifies ``MediaKeyInjector``: the Windows VK → macOS `NX_KEYTYPE_*`
/// mapping, the `data1` wire encoding used by `NSEventSubtypeMediaKey`, and
/// (when accessibility trust and an event tap are available) that
/// ``InputInjection.injectKeyboard`` posts a complete down+up system-defined
/// pair for a Windows media key-down while consuming the forwarded key-up.
final class MediaKeyInjectorTests: XCTestCase {

    // MARK: - VK ↔ NX key mapping

    func testMediaKeyRawValuesMapToExpectedCases() {
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xAD), .volumeMute)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xAE), .volumeDown)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xAF), .volumeUp)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xB0), .nextTrack)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xB1), .previousTrack)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xB2), .stop)
        XCTAssertEqual(MediaKeyInjector.MediaKey(rawValue: 0xB3), .playPause)
        // Just outside the media range must not be consumed as a media key.
        XCTAssertNil(MediaKeyInjector.MediaKey(rawValue: 0xAC))
        XCTAssertNil(MediaKeyInjector.MediaKey(rawValue: 0xB4))
    }

    func testNXKeyMappingMatchesIOKitConstants() {
        // NX_KEYTYPE_SOUND_UP / SOUND_DOWN / MUTE from ev_keymap.h.
        XCTAssertEqual(MediaKeyInjector.MediaKey.volumeUp.nxKey, 0)
        XCTAssertEqual(MediaKeyInjector.MediaKey.volumeDown.nxKey, 1)
        XCTAssertEqual(MediaKeyInjector.MediaKey.volumeMute.nxKey, 7)
        // NX_KEYTYPE_PLAY / NEXT / PREVIOUS.
        XCTAssertEqual(MediaKeyInjector.MediaKey.playPause.nxKey, 16)
        XCTAssertEqual(MediaKeyInjector.MediaKey.nextTrack.nxKey, 17)
        XCTAssertEqual(MediaKeyInjector.MediaKey.previousTrack.nxKey, 18)
    }

    func testStopHasNoMacOSCounterpart() {
        XCTAssertNil(MediaKeyInjector.MediaKey.stop.nxKey)
    }

    // MARK: - data1 encoding

    func testData1EncodingDownAndUp() {
        // Volume up (NX key 0): state 0xA down, 0xB up.
        XCTAssertEqual(MediaKeyInjector.data1(for: 0, isDown: true), 0x0A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 0, isDown: false), 0x0B00)
        // Play (NX key 16).
        XCTAssertEqual(MediaKeyInjector.data1(for: 16, isDown: true), 0x100A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 16, isDown: false), 0x100B00)
        // Next (NX key 17).
        XCTAssertEqual(MediaKeyInjector.data1(for: 17, isDown: true), 0x110A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 17, isDown: false), 0x110B00)
        // Previous (NX key 18).
        XCTAssertEqual(MediaKeyInjector.data1(for: 18, isDown: true), 0x120A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 18, isDown: false), 0x120B00)
        // Mute (NX key 7).
        XCTAssertEqual(MediaKeyInjector.data1(for: 7, isDown: true), 0x070A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 7, isDown: false), 0x070B00)
        // Volume down (NX key 1).
        XCTAssertEqual(MediaKeyInjector.data1(for: 1, isDown: true), 0x010A00)
        XCTAssertEqual(MediaKeyInjector.data1(for: 1, isDown: false), 0x010B00)
    }

    // MARK: - Consumption semantics

    func testNonMediaVKCodeIsNotConsumed() {
        // 'A' is an ordinary key: the injector must decline so the packet
        // falls through to keycode-based injection.
        XCTAssertFalse(MediaKeyInjector.inject(KeyboardData(vkCode: 0x41, flags: 0)))
    }

    func testStopKeyIsConsumedWithoutAction() {
        XCTAssertTrue(MediaKeyInjector.inject(KeyboardData(vkCode: 0xB2, flags: 0)))
    }

    // MARK: - Event-tap posting

    func testVolumeUpInjectionPostsDownAndUpSystemDefinedPair() throws {
        // CGEventPost is silently dropped for processes without accessibility
        // trust; nothing would be observable. The sequence is then verified by
        // the manual Windows→Mac smoke test instead.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Test host lacks accessibility trust")
        }

        let tap = MediaKeyEventTap()
        guard tap.start(nxKey: 0) else {
            throw XCTSkip("No event tap available in this environment")
        }
        defer { tap.stop() }

        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xAF, flags: 0))  // VK_VOLUME_UP

        let observed = tap.waitForObservations(2)
        XCTAssertEqual(observed.count, 2, "one Windows key-down must post exactly one down+up pair")
        XCTAssertEqual(observed.map(\.data1), [0x0A00, 0x0B00])
        for event in observed {
            XCTAssertEqual(event.subtype, 8, "media keys use NSEventSubtypeMediaKey")
            XCTAssertEqual(event.data2, -1)
            XCTAssertEqual(
                event.type.rawValue, UInt32(NSEvent.EventType.systemDefined.rawValue),
                "media keys must be posted as systemDefined events, not CG keycodes")
        }
    }

    func testVolumeUpKeyReleaseIsConsumed() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Test host lacks accessibility trust")
        }

        let tap = MediaKeyEventTap()
        guard tap.start(nxKey: 0) else {
            throw XCTSkip("No event tap available in this environment")
        }
        defer { tap.stop() }

        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xAF, flags: LLKHFFlag.up.rawValue))

        // The Windows key-up must not produce a second media action.
        let observed = tap.waitForObservations(1, timeout: 0.3)
        XCTAssertTrue(observed.isEmpty, "the forwarded key-up must be consumed without posting")
    }
}

// MARK: - Test event tap

/// Session-level tap that observes (and when possible suppresses) the
/// system-defined media-key events ``MediaKeyInjector`` posts during tests.
/// Mirrors the CGEventTap bridge pattern used by `InputInjectionTests`.
private final class MediaKeyEventTap {
    struct Observed {
        let type: CGEventType
        let subtype: Int16
        let data1: Int
        let data2: Int
        let eventNumber: Int64
    }

    private let lock = NSLock()
    private var observations: [Observed] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppress = false
    private var expectedNXKey: UInt32 = 0

    /// Creates a session tap for systemDefined events carrying `nxKey`.
    /// Prefers an active (suppressing) tap so the media action never reaches
    /// the system; falls back to listen-only. Returns false if neither can
    /// be created (e.g. headless session).
    @discardableResult
    func start(nxKey: UInt32) -> Bool {
        expectedNXKey = nxKey
        mediaKeyEventTapBridge = self

        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue

        var created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyEventTapCallback,
            userInfo: nil
        )
        suppress = created != nil
        if created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: mediaKeyEventTapCallback,
                userInfo: nil
            )
        }
        guard let tap = created else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        mediaKeyEventTapBridge = nil
    }

    /// Pumps the main run loop until `count` observations arrive or the
    /// timeout elapses, then returns everything observed.
    func waitForObservations(_ count: Int, timeout: TimeInterval = 2) -> [Observed] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ observations.count }) >= count {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return lock.withLock { observations }
    }

    /// Records the event when it is a media-key event for `expectedNXKey`;
    /// returns whether the event should be suppressed from delivery to apps.
    func handle(_ event: CGEvent) -> Bool {
        guard event.type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8,
              UInt32(truncatingIfNeeded: nsEvent.data1 >> 16) == expectedNXKey
        else {
            return false
        }
        let observed = Observed(
            type: event.type,
            subtype: nsEvent.subtype.rawValue,
            data1: nsEvent.data1,
            data2: nsEvent.data2,
            eventNumber: event.getIntegerValueField(CGEventField(rawValue: 98)!))
        lock.withLock { observations.append(observed) }
        return suppress
    }
}

/// Bridge for the C callback (closures with captures cannot be C function
/// pointers).
nonisolated(unsafe) private var mediaKeyEventTapBridge: MediaKeyEventTap?

private func mediaKeyEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }
    guard let bridge = mediaKeyEventTapBridge else {
        return Unmanaged.passUnretained(event)
    }
    return bridge.handle(event) ? nil : Unmanaged.passUnretained(event)
}
