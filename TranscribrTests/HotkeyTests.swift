import CoreGraphics
import XCTest
@testable import Transcribr

final class HotkeyTests: XCTestCase {
    // MARK: - Default

    func test_default_matchesSpec_inKeyCodeFlagsAndDescription() {
        let d = Hotkey.default
        XCTAssertEqual(d.keyCode, 50)
        XCTAssertEqual(
            d.flags,
            CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
        )
        XCTAssertEqual(d.description, "Fn+⇧+`")
    }

    func test_modifierMask_includesAllFiveExpectedBits() {
        let expected =
            CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(Hotkey.modifierMask, expected)
    }

    // MARK: - Initialisation masks extras

    func test_init_stripsCapsLockBit() {
        let capsLock: UInt64 = CGEventFlags.maskAlphaShift.rawValue
        let hotkey = Hotkey(keyCode: 0, flags: CGEventFlags.maskCommand.rawValue | capsLock)
        XCTAssertEqual(hotkey.flags, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(hotkey.flags & capsLock, 0)
    }

    func test_init_stripsAllNonModifierBits() {
        // Set every bit we should *not* keep, plus one we should: Command.
        let dirty: UInt64 = 0xFFFFFFFF_FFFFFFFF
        let hotkey = Hotkey(keyCode: 0, flags: dirty)
        XCTAssertEqual(hotkey.flags, Hotkey.modifierMask)
        XCTAssertEqual(hotkey.flags & ~Hotkey.modifierMask, 0)
    }

    // MARK: - JSON round-trip

    func test_jsonRoundTrip_preservesKeyCodeAndFlags() throws {
        let original = Hotkey(
            keyCode: 50,
            flags: CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.keyCode, 50)
        XCTAssertEqual(
            decoded.flags,
            CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
        )
    }

    func test_jsonDecode_stripsExtraBitsFromPersistedFlags() throws {
        let payload = #"{"keyCode":50,"flags":18446744073709551615}"# // UInt64.max
        let decoded = try JSONDecoder().decode(Hotkey.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.flags, Hotkey.modifierMask)
        XCTAssertEqual(decoded.flags & CGEventFlags.maskAlphaShift.rawValue, 0)
    }

    // MARK: - Description

    func test_description_eachModifierRendersExpectedGlyph() {
        XCTAssertEqual(
            Hotkey(keyCode: 0, flags: CGEventFlags.maskSecondaryFn.rawValue).description,
            "Fn+A"
        )
        XCTAssertEqual(
            Hotkey(keyCode: 0, flags: CGEventFlags.maskControl.rawValue).description,
            "⌃+A"
        )
        XCTAssertEqual(
            Hotkey(keyCode: 0, flags: CGEventFlags.maskAlternate.rawValue).description,
            "⌥+A"
        )
        XCTAssertEqual(
            Hotkey(keyCode: 0, flags: CGEventFlags.maskShift.rawValue).description,
            "⇧+A"
        )
        XCTAssertEqual(
            Hotkey(keyCode: 0, flags: CGEventFlags.maskCommand.rawValue).description,
            "⌘+A"
        )
    }

    func test_description_combinedModifiers_followApplePreferredOrder() {
        // Apple HIG order, with our Fn prefix: Fn, ⌃, ⌥, ⇧, ⌘, then key.
        let allMods = Hotkey.modifierMask
        XCTAssertEqual(
            Hotkey(keyCode: 46 /* M */, flags: allMods).description,
            "Fn+⌃+⌥+⇧+⌘+M"
        )
        XCTAssertEqual(
            Hotkey(
                keyCode: 46,
                flags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
            ).description,
            "⇧+⌘+M"
        )
    }

    func test_description_unmappedKeyCodeFallsBackToKeyN() {
        let hotkey = Hotkey(keyCode: 999, flags: CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(hotkey.description, "⌘+Key 999")
    }

    // MARK: - Validation

    func test_isValidForGlobal_rejectsAlphabeticKeyWithoutModifiers() {
        XCTAssertFalse(Hotkey.isValidForGlobal(keyCode: 0 /* A */, flags: 0))
        XCTAssertFalse(Hotkey.isValidForGlobal(keyCode: 46 /* M */, flags: 0))
    }

    func test_isValidForGlobal_rejectsDigitKeyWithoutModifiers() {
        XCTAssertFalse(Hotkey.isValidForGlobal(keyCode: 18 /* 1 */, flags: 0))
        XCTAssertFalse(Hotkey.isValidForGlobal(keyCode: 29 /* 0 */, flags: 0))
    }

    func test_isValidForGlobal_rejectsAlphanumericWithOnlyCapsLockBit() {
        // CapsLock is outside our modifierMask, so it does not count as a modifier — a plain
        // letter pressed with Caps Lock on must still be rejected.
        XCTAssertFalse(
            Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskAlphaShift.rawValue)
        )
    }

    func test_isValidForGlobal_acceptsAlphanumericWithAnyRealModifier() {
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskShift.rawValue))
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskControl.rawValue))
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskAlternate.rawValue))
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskCommand.rawValue))
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 0, flags: CGEventFlags.maskSecondaryFn.rawValue))
    }

    func test_isValidForGlobal_acceptsEscapeWithoutModifiers() {
        // Esc is not alphanumeric — caller knows what they're doing.
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 53, flags: 0))
    }

    func test_isValidForGlobal_acceptsFunctionKeyWithoutModifiers() {
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 122 /* F1 */, flags: 0))
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 96 /* F5 */, flags: 0))
    }

    func test_isValidForGlobal_acceptsSpaceWithoutModifiers() {
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 49 /* Space */, flags: 0))
    }

    func test_isValidForGlobal_acceptsUnmappedKeyCodeWithoutModifiers() {
        // We default to "allow" for codes we don't know — better than over-rejecting and
        // blocking valid international/special keys we just don't have a label for.
        XCTAssertTrue(Hotkey.isValidForGlobal(keyCode: 999, flags: 0))
    }
}
