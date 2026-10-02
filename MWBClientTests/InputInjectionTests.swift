import CoreGraphics
import XCTest
@testable import MWBClient

/// Verifies the pure logic of ``InputInjection``: drag-aware move typing,
/// modifier flag synthesis, Caps Lock toggle semantics, releaseAllKeys, the
/// Option/Command swap, and scroll inversion.
///
/// The tests assert synthesized state, not posted events, so they run without
/// the Accessibility permission.
final class InputInjectionTests: XCTestCase {

    // MARK: - Drag-aware move typing

    func testMoveEventTypeMapsDrags() {
        XCTAssertEqual(InputInjection.moveEventType(left: true, right: false, other: false), .leftMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: true, other: false), .rightMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: false, other: true), .otherMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: false, other: false), .mouseMoved)
        // Left button wins when several are held.
        XCTAssertEqual(InputInjection.moveEventType(left: true, right: true, other: true), .leftMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: true, other: true), .rightMouseDragged)
    }

    // MARK: - Modifier flag synthesis

    func testModifierFlagsAccumulate() {
        let none = InputInjection.modifierFlags(held: [], capsLockOn: false)
        XCTAssertTrue(none.isEmpty)

        let cmd = InputInjection.modifierFlags(held: [0x37], capsLockOn: false)
        XCTAssertTrue(cmd.contains(.maskCommand))
        XCTAssertFalse(cmd.contains(.maskControl))
        XCTAssertFalse(cmd.contains(.maskAlternate))

        let leftAndRightControl = InputInjection.modifierFlags(held: [0x3B, 0x3E], capsLockOn: false)
        XCTAssertTrue(leftAndRightControl.contains(.maskControl))
        XCTAssertFalse(leftAndRightControl.contains(.maskCommand))

        let all: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36]
        let everything = InputInjection.modifierFlags(held: all, capsLockOn: true)
        XCTAssertTrue(everything.contains(.maskShift))
        XCTAssertTrue(everything.contains(.maskControl))
        XCTAssertTrue(everything.contains(.maskAlternate))
        XCTAssertTrue(everything.contains(.maskCommand))
        XCTAssertTrue(everything.contains(.maskAlphaShift))
        // Fn / numeric pad state is never synthesized.
        XCTAssertFalse(everything.contains(.maskSecondaryFn))
        XCTAssertFalse(everything.contains(.maskNumericPad))
    }

    func testHeldModifiersTrackInjection() {
        let injection = InputInjection()

        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL down
        XCTAssertEqual(injection.heldModifiers, [0x3B])
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskControl))

        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: LLKHFFlag.up.rawValue))
        XCTAssertTrue(injection.heldModifiers.isEmpty)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskControl))
    }

    func testCapsLockTogglesPerKeyDown() {
        let injection = InputInjection()
        let capsDown = KeyboardData(vkCode: 0x14, flags: 0)
        let capsUp = KeyboardData(vkCode: 0x14, flags: LLKHFFlag.up.rawValue)

        injection.injectKeyboard(capsDown)
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))

        // Key up must be ignored: the lock state only changes on key down.
        injection.injectKeyboard(capsUp)
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))

        // Second key down toggles the lock off.
        injection.injectKeyboard(capsDown)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskAlphaShift))
    }

    func testSwapOptionCommandRemapsModifiers() {
        let injection = InputInjection()
        let winDown = KeyboardData(vkCode: 0x5B, flags: 0)  // VK_LWIN

        injection.injectKeyboard(winDown, swapOptionCommand: false)
        XCTAssertEqual(injection.heldModifiers, [0x37], "default: Win -> Command")

        injection.injectKeyboard(KeyboardData(vkCode: 0x5B, flags: LLKHFFlag.up.rawValue), swapOptionCommand: false)
        XCTAssertTrue(injection.heldModifiers.isEmpty)

        injection.injectKeyboard(winDown, swapOptionCommand: true)
        XCTAssertEqual(injection.heldModifiers, [0x3A], "swapped: Win -> Option")
    }

    func testReleaseAllKeysClearsState() {
        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL
        injection.injectKeyboard(KeyboardData(vkCode: 0x5B, flags: 0))  // VK_LWIN
        injection.injectKeyboard(KeyboardData(vkCode: 0x14, flags: 0))  // VK_CAPITAL (locks on)
        XCTAssertEqual(injection.heldModifiers.count, 2)

        injection.releaseAllKeys()
        XCTAssertTrue(injection.heldModifiers.isEmpty)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskControl))
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskCommand))
        // Caps Lock survives releaseAllKeys (hardware toggle semantics).
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))
    }

    func testResetReleasesModifiers() {
        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL
        injection.reset()
        XCTAssertTrue(injection.heldModifiers.isEmpty)
    }

    // MARK: - Scroll inversion

    func testScrollPixelConversion() {
        XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: false), 3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: -120, invert: false), -3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 240, invert: false), 6)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 0, invert: false), 0)
        // Inverted flips the direction.
        XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: true), -3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: -120, invert: true), 3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 0, invert: true), 0)
    }
}
