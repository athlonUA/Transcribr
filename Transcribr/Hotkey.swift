import CoreGraphics
import Foundation

/// A keyboard combination intended to be matched against `CGEvent`s in a global event tap.
///
/// `flags` stores the raw `CGEventFlags` value of the modifiers; we always mask it down to
/// the bits we actually care about (`modifierMask`) on construction so that stray state bits
/// like Caps Lock or Num Lock — which `NSEvent.modifierFlags` happily reports — never end up
/// in persisted JSON or in the runtime comparison. Without this, a user who happens to have
/// Caps Lock on would suddenly find their hotkey "not working".
struct Hotkey: Codable, Equatable, CustomStringConvertible {
    var keyCode: Int64
    var flags: UInt64

    /// Bits we treat as modifiers when comparing `event.flags & modifierMask` against
    /// `hotkey.flags & modifierMask`. Anything outside this mask (Caps Lock, Num Lock, Help,
    /// keyboard-type bits) is intentionally ignored.
    static let modifierMask: UInt64 =
        CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    /// Default: `Fn+⇧+\`` (keyCode 50 = `kVK_ANSI_Grave` on US layouts). Picked because it's
    /// unlikely to collide with anything users normally bind, and the Fn modifier makes it
    /// unreachable from `RegisterEventHotKey` (Carbon) — so we can't accidentally clash with
    /// a Carbon-registered shortcut from another app.
    static let `default` = Hotkey(
        keyCode: 50,
        flags: CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
    )

    init(keyCode: Int64, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags & Self.modifierMask
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case flags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(Int64.self, forKey: .keyCode)
        let rawFlags = try container.decode(UInt64.self, forKey: .flags)
        // Route through the masking initialiser so a tampered/legacy JSON with extra bits
        // (e.g. CapsLock left in from an older save format) gets cleaned up on load.
        self.init(keyCode: keyCode, flags: rawFlags)
    }

    // MARK: - Display

    /// Render order follows Apple HIG: Fn, Control, Option, Shift, Command, then key name.
    /// "+" separators (rather than Apple's no-separator menu style) make the string easier to
    /// read in a settings row outside a real menu context.
    var description: String {
        var parts: [String] = []
        if flags & CGEventFlags.maskSecondaryFn.rawValue != 0 { parts.append("Fn") }
        if flags & CGEventFlags.maskControl.rawValue != 0 { parts.append("⌃") }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if flags & CGEventFlags.maskShift.rawValue != 0 { parts.append("⇧") }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: keyCode))
        return parts.joined(separator: "+")
    }

    // MARK: - Validation

    /// Reject hotkeys that would globally swallow a plain letter or digit — those would steal
    /// the keystroke from every other app the moment the user typed it. Non-alphanumeric keys
    /// (Esc, F-keys, arrows, Space, punctuation) without modifiers are allowed: the user is
    /// explicitly opting in and we don't second-guess them.
    static func isValidForGlobal(keyCode: Int64, flags: UInt64) -> Bool {
        let masked = flags & modifierMask
        if masked == 0, KeyCodeNames.isAlphanumeric(keyCode) {
            return false
        }
        return true
    }
}

/// US-layout virtual key codes from `<HIToolbox/Events.h>` (`kVK_*`). We hardcode the
/// commonly-bound subset rather than calling `UCKeyTranslate`, which depends on the user's
/// current keyboard layout and would render differently on, say, AZERTY vs QWERTY for the
/// same `keyCode`. A label like "Key 99" for an unmapped code is an acceptable fallback for
/// the MVP — the binding still works; only its label looks ugly.
private enum KeyCodeNames {
    private static let names: [Int64: String] = [
        // Letters (kVK_ANSI_A … kVK_ANSI_Z)
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F",
        5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R",
        1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // Digit row
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        // Whitespace / control
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Esc", 117: "ForwardDelete", 76: "Enter",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function row
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        // Numpad
        82: "Pad0", 83: "Pad1", 84: "Pad2", 85: "Pad3", 86: "Pad4",
        87: "Pad5", 88: "Pad6", 89: "Pad7", 91: "Pad8", 92: "Pad9",
    ]

    /// Subset of keyCodes for which `isValidForGlobal` rejects the no-modifier case.
    /// Derived from the letters + digit-row entries above; kept as a separate `Set` so the
    /// lookup in `isValidForGlobal` stays O(1) regardless of `names` size.
    private static let alphanumeric: Set<Int64> = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35,
        12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,
    ]

    static func name(for keyCode: Int64) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    static func isAlphanumeric(_ keyCode: Int64) -> Bool {
        alphanumeric.contains(keyCode)
    }
}
