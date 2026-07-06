import Foundation
import AppKit
import CoreGraphics

enum ControllerMode: Int {
    case off = 0
    case mirror = 1
    case multi = 2

    var label: String {
        switch self {
        case .off: return "OFF"
        case .mirror: return "MIRROR"
        case .multi: return "MULTI"
        }
    }
}

/// Captures global keyboard input via a CGEvent tap and routes it to the
/// assigned Toontown Rewritten processes with `postToPid` (no focus needed).
final class InputEngine {

    // MARK: - State

    var settings: Settings {
        didSet { settings.save() }
    }

    /// Control slots. 0 = Group 1 Left, 1 = Group 1 Right,
    ///                2 = Group 2 Left, 3 = Group 2 Right.
    private(set) var slots: [ToonWindow?] = [nil, nil, nil, nil]

    private(set) var mode: ControllerMode = .off

    /// True while the player is typing in the game's chat box.
    /// Entered/exited with Return, exited with Esc. While chatting, keys are
    /// not translated so typed words don't lose bound letters.
    private(set) var chatMode: Bool = false

    /// Set true while the UI is capturing a keybind; the tap passes everything through.
    var suspended: Bool = false

    /// Whether the frontmost app is one we should control from (a Toontown
    /// window or this app). Kept fresh by an NSWorkspace observer so the
    /// event tap never has to ask the system.
    private(set) var frontmostControllable: Bool = true

    /// True when smart focus is holding input back because another app is focused.
    var controlPaused: Bool {
        mode != .off && settings.smartFocus && !frontmostControllable
    }

    /// Fired on the main thread whenever mode/group/slots change.
    var onStateChange: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var frontmostObserver: NSObjectProtocol?

    /// Marker placed on synthesized events so our own tap ignores them.
    private static let syntheticMarker: Int64 = 0x77545243

    // MARK: - Lifecycle

    /// Pids of every discovered Toontown window, fed in by the app's discovery
    /// loop so smart focus recognizes game windows even when the process name
    /// doesn't match what we expect.
    private var knownToonPids: Set<pid_t> = []

    init(settings: Settings) {
        self.settings = settings

        refreshFrontmost()
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFrontmost()
        }
    }

    deinit {
        if let observer = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Called by the discovery loop (~every 2 s) with the pids of all
    /// Toontown windows currently on screen.
    func setKnownToonPids(_ pids: Set<pid_t>) {
        if knownToonPids != pids {
            knownToonPids = pids
        }
        refreshFrontmost()
    }

    private var lastFrontmostPid: pid_t = -1

    /// Re-evaluates whether the frontmost app is one we should control from.
    /// Cheap; called on app switches, slot changes, and the discovery loop
    /// so the state can never go stale.
    func refreshFrontmost() {
        let controllable: Bool
        if let app = NSWorkspace.shared.frontmostApplication {
            let pid = app.processIdentifier

            // Switching windows abandons any in-progress chat, so leave chat
            // passthrough rather than staying stuck in it.
            if pid != lastFrontmostPid {
                lastFrontmostPid = pid
                setChatMode(false)
            }
            if pid == ProcessInfo.processInfo.processIdentifier {
                controllable = true
            } else if slots.contains(where: { $0?.pid == pid }) {
                controllable = true
            } else if knownToonPids.contains(pid) {
                controllable = true
            } else {
                let name = (app.localizedName ?? "").lowercased()
                controllable = name.contains("toontown") && !name.contains("launcher")
            }
        } else {
            controllable = true   // unknown frontmost app: don't break control
        }

        if frontmostControllable != controllable {
            frontmostControllable = controllable
            notifyStateChange()
        }
    }

    var tapIsRunning: Bool { tap != nil }

    /// Creates the event tap. Returns false if the system refused
    /// (almost always a missing Accessibility permission).
    @discardableResult
    func startTap() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let engine = Unmanaged<InputEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else { return false }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func stopTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Slots & mode

    func assign(_ window: ToonWindow?, toSlot index: Int) {
        guard slots.indices.contains(index) else { return }
        if let window = window {
            // A window may live in only one slot.
            for i in slots.indices where i != index && slots[i]?.windowID == window.windowID {
                slots[i] = nil
            }
        }
        slots[index] = window
        refreshFrontmost()
        notifyStateChange()
    }

    /// Fill empty slots with discovered windows, in order.
    func autoAssign(from windows: [ToonWindow]) {
        var remaining = windows.filter { w in
            !slots.contains(where: { $0?.windowID == w.windowID })
        }
        for i in slots.indices where slots[i] == nil && !remaining.isEmpty {
            slots[i] = remaining.removeFirst()
        }
        refreshFrontmost()
        notifyStateChange()
    }

    /// Drop slots whose process has exited. Returns true if anything changed.
    @discardableResult
    func pruneDeadSlots() -> Bool {
        var changed = false
        for i in slots.indices {
            if let w = slots[i], !WindowTracker.isProcessAlive(w.pid) {
                slots[i] = nil
                changed = true
            }
        }
        if changed { notifyStateChange() }
        return changed
    }

    func setMode(_ newMode: ControllerMode) {
        guard mode != newMode else { return }
        mode = newMode
        chatMode = false
        notifyStateChange()
    }

    private func cycleMode() {
        switch mode {
        case .off: mode = .mirror
        case .mirror: mode = .multi
        case .multi: mode = .off
        }
        chatMode = false
        notifyStateChange()
    }

    private func setChatMode(_ value: Bool) {
        guard chatMode != value else { return }
        chatMode = value
        notifyStateChange()
    }

    private func notifyStateChange() {
        if Thread.isMainThread {
            onStateChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }
    }

    private var assignedPids: [pid_t] {
        var seen = Set<pid_t>()
        var pids: [pid_t] = []
        for slot in slots {
            if let pid = slot?.pid, !seen.contains(pid) {
                seen.insert(pid)
                pids.append(pid)
            }
        }
        return pids
    }

    /// Pids of the toons in a group (0 = Group 1 → slots 0+1,
    /// 1 = Group 2 → slots 2+3).
    private func pids(inGroup group: Int) -> [pid_t] {
        [slots[group * 2], slots[group * 2 + 1]].compactMap { $0?.pid }
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // The system disables taps that stall or when secure input starts; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        // Ignore events we synthesized ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == InputEngine.syntheticMarker {
            return pass
        }

        if suspended { return pass }

        // Smart focus: while another app is frontmost, touch nothing — typing
        // in a browser or chat app never reaches your toons, and the toggle
        // key types normally too.
        if settings.smartFocus && !frontmostControllable { return pass }

        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Resolve down/up (flagsChanged carries the modifier's keycode).
        let isDown: Bool
        var isRepeat = false
        switch type {
        case .keyDown:
            isDown = true
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        case .keyUp:
            isDown = false
        case .flagsChanged:
            guard let bit = VK.modifierFlag(for: keycode) else { return pass }
            isDown = flags.contains(bit)
        default:
            return pass
        }

        // Toggle key always works (unless Command is held).
        if keycode == settings.toggleKey && !flags.contains(.maskCommand) {
            if isDown && !isRepeat { cycleMode() }
            return nil
        }

        guard mode != .off else { return pass }

        // Never intercept Command shortcuts (⌘Q, ⌘Tab, etc.).
        if flags.contains(.maskCommand) { return pass }

        switch mode {
        case .mirror:
            return handleMirror(keycode: keycode, isDown: isDown, isRepeat: isRepeat,
                                flags: flags, passthrough: pass)
        case .multi:
            return handleMulti(keycode: keycode, isDown: isDown, isRepeat: isRepeat,
                               passthrough: pass)
        case .off:
            return pass
        }
    }

    /// Mirror mode: every key you press is duplicated to all assigned toons.
    /// The configured throw binds are translated to the game's throw control —
    /// except while chatting, so typed words keep every letter.
    private func handleMirror(keycode: CGKeyCode, isDown: Bool, isRepeat: Bool,
                              flags: CGEventFlags, passthrough: Unmanaged<CGEvent>)
        -> Unmanaged<CGEvent>? {

        let pids = assignedPids
        guard !pids.isEmpty else { return passthrough }

        // Return toggles chat on all toons at once (open → type → send).
        if keycode == VK.returnKey || keycode == VK.keypadEnter {
            if isDown && !isRepeat { setChatMode(!chatMode) }
            mirrorRaw(keycode: keycode, isDown: isDown, isRepeat: isRepeat,
                      flags: flags, to: pids)
            return nil
        }

        if chatMode {
            // Esc cancels the chat box.
            if keycode == VK.escape && isDown { setChatMode(false) }
            // Mirror everything untranslated while typing.
            mirrorRaw(keycode: keycode, isDown: isDown, isRepeat: isRepeat,
                      flags: flags, to: pids)
            return nil
        }

        let isThrowBind = keycode == settings.leftBinds[.throwGag]
                       || keycode == settings.rightBinds[.throwGag]

        if isThrowBind {
            // Pure 1:1 key mapping — your real press and release, translated
            // to your in-game throw control.
            for pid in pids {
                postKey(inGameKey(for: .throwGag), down: isDown,
                        isRepeat: isRepeat, flags: nil, pid: pid)
            }
            return nil
        }

        mirrorRaw(keycode: keycode, isDown: isDown, isRepeat: isRepeat,
                  flags: flags, to: pids)
        return nil
    }

    /// Duplicate a keystroke unmodified, preserving flags (minus Command)
    /// so Shift+letter etc. survives.
    private func mirrorRaw(keycode: CGKeyCode, isDown: Bool, isRepeat: Bool,
                           flags: CGEventFlags, to pids: [pid_t]) {
        let carried = flags.subtracting(.maskCommand)
        for pid in pids {
            postKey(keycode, down: isDown, isRepeat: isRepeat, flags: carried, pid: pid)
        }
    }

    /// Multi mode: both groups are always live. Group 1's keybinds drive every
    /// toon in Group 1 and Group 2's keybinds drive every toon in Group 2,
    /// simultaneously — every press translated to the user's in-game controls
    /// (their Group 1 binds).
    private func handleMulti(keycode: CGKeyCode, isDown: Bool, isRepeat: Bool,
                             passthrough: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {

        // Return opens/sends chat in whichever window has focus; while chatting,
        // all keys pass through untouched so typing works normally.
        if keycode == VK.returnKey || keycode == VK.keypadEnter {
            if isDown && !isRepeat { setChatMode(!chatMode) }
            return passthrough
        }
        if chatMode {
            if keycode == VK.escape && isDown { setChatMode(false) }
            return passthrough
        }

        let group1Actions = actions(for: keycode, in: settings.leftBinds)
        let group2Actions = actions(for: keycode, in: settings.rightBinds)

        guard !group1Actions.isEmpty || !group2Actions.isEmpty else {
            return passthrough   // unmapped keys behave normally
        }

        for pid in pids(inGroup: 0) {
            deliver(actions: group1Actions, to: pid, isDown: isDown, isRepeat: isRepeat)
        }
        for pid in pids(inGroup: 1) {
            deliver(actions: group2Actions, to: pid, isDown: isDown, isRepeat: isRepeat)
        }
        return nil
    }

    private func actions(for keycode: CGKeyCode,
                         in binds: [GameAction: CGKeyCode]) -> [GameAction] {
        binds.compactMap { $0.value == keycode ? $0.key : nil }
    }

    /// The key the game actually understands for an action: the user's
    /// Group 1 bind, which doubles as their in-game TTR control.
    private func inGameKey(for action: GameAction) -> CGKeyCode {
        settings.leftBinds[action] ?? action.gameKeycode
    }

    private func deliver(actions: [GameAction], to pid: pid_t,
                         isDown: Bool, isRepeat: Bool) {
        for action in actions {
            postKey(inGameKey(for: action), down: isDown, isRepeat: isRepeat,
                    flags: nil, pid: pid)
        }
    }

    /// Synthesize a keyboard event and post it directly to a process.
    /// Modifier keys (Control, Shift, …) are delivered as `flagsChanged`
    /// events — exactly like real hardware — because game engines ignore
    /// modifiers that arrive as plain keyDown/keyUp. This is what makes
    /// Jump (Control) work.
    private func postKey(_ keycode: CGKeyCode, down: Bool, isRepeat: Bool,
                         flags: CGEventFlags?, pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: keycode, keyDown: down) else { return }

        if let modifierBit = VK.modifierFlag(for: keycode) {
            event.type = .flagsChanged
            var eventFlags = flags ?? []
            eventFlags.remove(modifierBit)
            if down { eventFlags.insert(modifierBit) }
            event.flags = eventFlags
        } else {
            // Arrow keys / forward delete always need their hardware flags to
            // be recognized, even when carrying the user's original flags.
            var eventFlags = flags ?? []
            eventFlags.formUnion(requiredFlags(for: keycode))
            event.flags = eventFlags
            if isRepeat {
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
        }

        event.setIntegerValueField(.eventSourceUserData,
                                   value: InputEngine.syntheticMarker)
        event.postToPid(pid)
    }

    private func requiredFlags(for keycode: CGKeyCode) -> CGEventFlags {
        switch keycode {
        case VK.arrowUp, VK.arrowDown, VK.arrowLeft, VK.arrowRight:
            return [.maskSecondaryFn, .maskNumericPad]
        case VK.forwardDelete:
            return .maskSecondaryFn
        default:
            return []
        }
    }
}
