import AppKit
import Combine
import CoreGraphics

/// Bridges the InputEngine to SwiftUI. All access happens on the main thread.
final class ControllerViewModel: ObservableObject {

    private let engine: InputEngine
    private let tracker: WindowTracker

    @Published private(set) var mode: ControllerMode = .off
    @Published private(set) var chatMode: Bool = false
    @Published private(set) var controlPaused: Bool = false
    @Published private(set) var slots: [ToonWindow?] = [nil, nil, nil, nil]
    @Published private(set) var discovered: [ToonWindow] = []
    @Published private(set) var tapRunning: Bool = false
    /// Identifier of the keybind button currently waiting for a keypress.
    @Published private(set) var capturingBindID: String?
    /// Slot currently waiting for the user to click a Toontown window.
    @Published private(set) var pickingSlot: Int?

    private var keyMonitor: Any?
    private var pickMonitor: Any?

    static let slotTitles = [
        "Group 1 · Toon A", "Group 1 · Toon B",
        "Group 2 · Toon A", "Group 2 · Toon B"
    ]

    init(engine: InputEngine, tracker: WindowTracker) {
        self.engine = engine
        self.tracker = tracker
        refresh()
        refreshDiscovered()
    }

    // MARK: - State sync (called by AppDelegate on engine changes / timers)

    func refresh() {
        mode = engine.mode
        chatMode = engine.chatMode
        controlPaused = engine.controlPaused
        slots = engine.slots
        tapRunning = engine.tapIsRunning
    }

    func refreshDiscovered() {
        let latest = tracker.discover()
        if latest != discovered {
            discovered = latest
        }
    }

    // MARK: - Intents

    func setMode(_ newMode: ControllerMode) {
        engine.setMode(newMode)
    }

    func assign(windowID: CGWindowID?, toSlot index: Int) {
        guard let windowID = windowID else {
            engine.assign(nil, toSlot: index)
            return
        }
        let window = discovered.first { $0.windowID == windowID }
            ?? slots.compactMap { $0 }.first { $0.windowID == windowID }
        engine.assign(window, toSlot: index)
    }

    func autoFill() {
        refreshDiscovered()
        engine.autoAssign(from: discovered)
    }

    // MARK: - Click-to-pick

    /// Arms (or disarms) window picking for a slot. While armed, the next
    /// click on a Toontown window assigns it; clicking anything else cancels.
    func togglePick(slot: Int) {
        if pickingSlot == slot {
            endPick()
            return
        }
        cancelCapture()
        endPick()
        pickingSlot = slot

        pickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] _ in
            self?.handlePickClick()
        }
    }

    private func handlePickClick() {
        guard let slot = pickingSlot else { return }
        let quartzPoint = WindowTracker.quartzPoint(fromCocoa: NSEvent.mouseLocation)
        if let window = tracker.toonWindow(atQuartzPoint: quartzPoint) {
            engine.assign(window, toSlot: slot)
            refreshDiscovered()
        }
        endPick()
    }

    func endPick() {
        if let monitor = pickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        pickMonitor = nil
        pickingSlot = nil
    }

    // MARK: - Settings passthrough

    var smartFocus: Bool { engine.settings.smartFocus }
    func setSmartFocus(_ value: Bool) {
        objectWillChange.send()
        engine.settings.smartFocus = value
        refresh()   // recompute the paused state immediately
    }

    var toggleKey: CGKeyCode { engine.settings.toggleKey }
    func setToggleKey(_ code: CGKeyCode) {
        objectWillChange.send()
        engine.settings.toggleKey = code
    }

    func bind(side: ToonSide, action: GameAction) -> CGKeyCode {
        let binds = side == .left ? engine.settings.leftBinds : engine.settings.rightBinds
        return binds[action] ?? 0
    }

    func setBind(side: ToonSide, action: GameAction, code: CGKeyCode) {
        objectWillChange.send()
        if side == .left {
            engine.settings.leftBinds[action] = code
        } else {
            engine.settings.rightBinds[action] = code
        }
    }

    // MARK: - Keybind capture

    func beginCapture(id: String, onSet: @escaping (CGKeyCode) -> Void) {
        cancelCapture()
        endPick()
        capturingBindID = id
        engine.suspended = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self = self else { return event }

            let code = CGKeyCode(event.keyCode)
            if event.type == .flagsChanged {
                // Accept only modifier *presses*, never Command keys.
                guard let flag = Self.nsModifierFlag(for: code),
                      event.modifierFlags.contains(flag),
                      flag != .command
                else { return nil }
            }

            self.cancelCapture()
            onSet(code)
            return nil   // swallow the keystroke
        }
    }

    func cancelCapture() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        engine.suspended = false
        capturingBindID = nil
    }

    private static func nsModifierFlag(for keycode: CGKeyCode) -> NSEvent.ModifierFlags? {
        switch keycode {
        case VK.leftShift, VK.rightShift: return .shift
        case VK.leftControl, VK.rightControl: return .control
        case VK.leftOption, VK.rightOption: return .option
        case VK.leftCommand, VK.rightCommand: return .command
        default: return nil
        }
    }

    // MARK: - Permission

    func retryTapOrOpenSettings() {
        if engine.startTap() {
            refresh()
            return
        }
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
