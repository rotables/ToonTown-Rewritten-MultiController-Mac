import Foundation
import CoreGraphics

/// macOS virtual keycodes (kVK_*) used throughout the app.
enum VK {
    static let a: CGKeyCode = 0x00
    static let s: CGKeyCode = 0x01
    static let d: CGKeyCode = 0x02
    static let w: CGKeyCode = 0x0D
    static let e: CGKeyCode = 0x0E
    static let escape: CGKeyCode = 0x35
    static let grave: CGKeyCode = 0x32          // ` (backtick)
    static let leftShift: CGKeyCode = 0x38
    static let rightShift: CGKeyCode = 0x3C
    static let leftControl: CGKeyCode = 0x3B
    static let rightControl: CGKeyCode = 0x3E
    static let leftOption: CGKeyCode = 0x3A
    static let rightOption: CGKeyCode = 0x3D
    static let leftCommand: CGKeyCode = 0x37
    static let rightCommand: CGKeyCode = 0x36
    static let forwardDelete: CGKeyCode = 0x75
    static let returnKey: CGKeyCode = 0x24
    static let keypadEnter: CGKeyCode = 0x4C
    static let arrowLeft: CGKeyCode = 0x7B
    static let arrowRight: CGKeyCode = 0x7C
    static let arrowDown: CGKeyCode = 0x7D
    static let arrowUp: CGKeyCode = 0x7E

    /// Flag bit that a given modifier keycode controls (for interpreting flagsChanged).
    static func modifierFlag(for keycode: CGKeyCode) -> CGEventFlags? {
        switch keycode {
        case leftShift, rightShift: return .maskShift
        case leftControl, rightControl: return .maskControl
        case leftOption, rightOption: return .maskAlternate
        case leftCommand, rightCommand: return .maskCommand
        default: return nil
        }
    }

    /// Human-readable name for a keycode (US layout).
    static func name(for keycode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
            0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
            0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
            0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
            0x30: "Tab", 0x31: "Space", 0x32: "`", 0x33: "Delete (⌫)",
            0x35: "Esc", 0x24: "Return", 0x4C: "Enter",
            0x37: "⌘", 0x36: "R⌘", 0x38: "Shift", 0x3C: "R-Shift",
            0x3A: "Option", 0x3D: "R-Option", 0x3B: "Control", 0x3E: "R-Control",
            0x75: "Fwd Delete (⌦)", 0x73: "Home", 0x77: "End",
            0x74: "Page Up", 0x79: "Page Down",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
            0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
            0x67: "F11", 0x6F: "F12"
        ]
        return names[keycode] ?? "Key \(keycode)"
    }
}

/// The controllable game actions. Delivery translates keys into the user's
/// Group 1 binds (which mirror their in-game TTR controls).
enum GameAction: String, Codable, CaseIterable {
    case forward, back, left, right, jump, throwGag, escape

    /// TTR's factory-default control for this action. Only used to seed
    /// defaults — actual delivery uses the user's Group 1 (in-game) binds.
    var gameKeycode: CGKeyCode {
        switch self {
        case .forward: return VK.arrowUp
        case .back: return VK.arrowDown
        case .left: return VK.arrowLeft
        case .right: return VK.arrowRight
        case .jump: return VK.leftControl
        case .throwGag: return VK.forwardDelete
        case .escape: return VK.escape
        }
    }

    var label: String {
        switch self {
        case .forward: return "Forward"
        case .back: return "Back"
        case .left: return "Left"
        case .right: return "Right"
        case .jump: return "Jump"
        case .throwGag: return "Throw"
        case .escape: return "Esc"
        }
    }
}

enum ToonSide: String, Codable {
    case left, right
}

struct Settings: Codable {
    /// Key that cycles Off → Mirror → Multi → Off.
    var toggleKey: CGKeyCode = VK.grave

    /// Group 1's keys — these are ALSO your actual in-game TTR controls.
    /// Whatever is set here is exactly what gets delivered to the game for
    /// each action, so if you've customized your TTR keybinds, set this
    /// column to match and everything works. Defaults = TTR's defaults.
    var leftBinds: [GameAction: CGKeyCode] = [
        .forward: VK.arrowUp,
        .back: VK.arrowDown,
        .left: VK.arrowLeft,
        .right: VK.arrowRight,
        .jump: VK.leftControl,
        .throwGag: VK.forwardDelete,
        .escape: VK.escape
    ]

    /// Group 2's keys — anything you like; each press is translated into the
    /// matching Group 1 (in-game) control before being sent to Group 2's toons.
    var rightBinds: [GameAction: CGKeyCode] = [
        .forward: VK.w,
        .back: VK.s,
        .left: VK.a,
        .right: VK.d,
        .jump: VK.leftShift,
        .throwGag: VK.e,
        .escape: VK.escape
    ]

    /// When true, input is only intercepted while a Toontown window (or this
    /// app) is frontmost — typing in other apps never controls your toons.
    var smartFocus: Bool = true

    init() {}

    // Custom decoding so settings saved by older versions (missing newer
    // fields) load cleanly instead of resetting everything to defaults.
    private enum CodingKeys: String, CodingKey {
        case toggleKey, leftBinds, rightBinds, smartFocus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        toggleKey = try c.decodeIfPresent(CGKeyCode.self, forKey: .toggleKey) ?? defaults.toggleKey
        leftBinds = try c.decodeIfPresent([GameAction: CGKeyCode].self, forKey: .leftBinds) ?? defaults.leftBinds
        rightBinds = try c.decodeIfPresent([GameAction: CGKeyCode].self, forKey: .rightBinds) ?? defaults.rightBinds
        smartFocus = try c.decodeIfPresent(Bool.self, forKey: .smartFocus) ?? defaults.smartFocus
    }

    // v2: bind semantics changed (Group 1 = in-game controls), so older
    // saved settings are deliberately not loaded.
    private static let defaultsKey = "TTRMultiControllerSettings.v2"

    static func load() -> Settings {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        return Settings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Settings.defaultsKey)
        }
    }
}
