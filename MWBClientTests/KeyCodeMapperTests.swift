import XCTest
@testable import MWBClient

/// Verifies the Windows VK -> macOS keycode modifier table against the
/// physical Mac keyboard layout, the Mac -> Windows reverse direction, and
/// the Option/Command swap helpers.
final class KeyCodeMapperTests: XCTestCase {

    // MARK: - Windows -> Mac modifier mapping

    func testControlModifiersMapToMacControl() {
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x11), 0x3B, "VK_CONTROL -> Left Control")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA2), 0x3B, "VK_LCONTROL -> Left Control")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA3), 0x3E, "VK_RCONTROL -> Right Control")
    }

    func testMenuModifiersMapToMacOption() {
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x12), 0x3A, "VK_MENU -> Left Option")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA4), 0x3A, "VK_LMENU -> Left Option")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA5), 0x3D, "VK_RMENU -> Right Option")
    }

    func testWinKeysMapToMacCommand() {
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x5B), 0x37, "VK_LWIN -> Left Command")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x5C), 0x36, "VK_RWIN -> Right Command")
    }

    func testShiftAndCapsLockMappings() {
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x10), 0x38, "VK_SHIFT -> Left Shift")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA0), 0x38, "VK_LSHIFT -> Left Shift")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xA1), 0x3C, "VK_RSHIFT -> Right Shift")
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x14), 0x39, "VK_CAPITAL -> Caps Lock")
    }

    // MARK: - Round trips

    /// Round trip Windows -> Mac -> Windows for the full modifier set.
    /// PowerToys sends the left/right-specific VK codes from its low-level
    /// keyboard hook, so the reverse direction must be deterministic.
    func testModifierRoundTrip() {
        let pairs: [(vk: UInt16, mac: UInt16)] = [
            (0xA0, 0x38), (0xA1, 0x3C),  // Shift
            (0xA2, 0x3B), (0xA3, 0x3E),  // Control
            (0xA4, 0x3A), (0xA5, 0x3D),  // Option / Alt
            (0x5B, 0x37), (0x5C, 0x36),  // Command / Win
            (0x14, 0x39),                // Caps Lock
        ]
        for pair in pairs {
            XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: pair.vk), pair.mac)
            XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: pair.mac), pair.vk,
                           "reverse mapping for mac keycode 0x\(String(pair.mac, radix: 16))")
        }
    }

    func testLettersRoundTrip() {
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0x41), 0x00, "VK 'A'")
        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x00), 0x41)
    }

    // MARK: - Option/Command swap

    func testSwappedModifierKeycode() {
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x3A), 0x37, "Option -> Command")
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x37), 0x3A, "Command -> Option")
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x3D), 0x36, "Right Option -> Right Command")
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x36), 0x3D, "Right Command -> Right Option")
        // Non-swappable keys pass through untouched.
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x00), 0x00)
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x3B), 0x3B, "Control is not swapped")
        XCTAssertEqual(KeyCodeMapper.swappedModifierKeycode(0x38), 0x38, "Shift is not swapped")
    }

    func testSwappedModifierVK() {
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0x5B), 0xA4, "VK_LWIN -> VK_LMENU")
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0xA4), 0x5B, "VK_LMENU -> VK_LWIN")
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0x5C), 0xA5, "VK_RWIN -> VK_RMENU")
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0xA5), 0x5C, "VK_RMENU -> VK_RWIN")
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0x41), 0x41, "'A' unchanged")
        XCTAssertEqual(KeyCodeMapper.swappedModifierVK(0xA2), 0xA2, "VK_LCONTROL unchanged")
    }

    /// Full round trip with the swap applied in both directions: Win/Alt VKs
    /// in, Option/Command keycodes out and back.
    func testSwapRoundTripAcrossDirections() {
        // Windows VK_LWIN with swap on lands on Mac Option...
        let macKeycode = KeyCodeMapper.swappedModifierKeycode(KeyCodeMapper.vkToMacOS(vkCode: 0x5B)!)
        XCTAssertEqual(macKeycode, 0x3A)
        // ...and a Mac Command keypress with swap on leaves as VK_LMENU.
        let vkOut = KeyCodeMapper.swappedModifierVK(KeyCodeMapper.macOSToVK(macOSKeycode: 0x37)!)
        XCTAssertEqual(vkOut, 0xA4)
    }
}
