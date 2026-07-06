import AppKit
import SwiftUI
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    static let appVersion = "1.0"

    private var window: NSWindow!
    private var model: ControllerViewModel!

    private let tracker = WindowTracker()
    private var engine: InputEngine!

    private var slowTimer: Timer?

    private var statusItem: NSStatusItem!
    private var statusModeItems: [ControllerMode: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = InputEngine(settings: Settings.load())

        buildMenu()
        buildWindow()
        buildStatusItem()
        requestAccessibilityIfNeeded()
        _ = engine.startTap()

        engine.onStateChange = { [weak self] in
            self?.model.refresh()
            self?.updateStatusItem()
        }
        model.refresh()
        updateStatusItem()

        // Housekeeping loop: rediscover Toontown windows, drop dead slots,
        // keep smart focus fresh, retry the tap if permission just arrived.
        slowTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.engine.pruneDeadSlots()
            self.model.refreshDiscovered()
            self.engine.setKnownToonPids(Set(self.model.discovered.map { $0.pid }))
            if !self.engine.tapIsRunning && AXIsProcessTrusted() {
                if self.engine.startTap() {
                    self.model.refresh()
                }
            }
        }
        slowTimer?.tolerance = 0.5
        slowTimer?.fire()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopTap()
    }

    // Closing the window keeps the app alive in the menu bar; quitting
    // (⌘Q or the menu bar's Quit) removes the menu bar item with the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func buildWindow() {
        model = ControllerViewModel(engine: engine, tracker: tracker)
        let hosting = NSHostingController(rootView: ContentView(model: model))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TTR MultiController"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 700))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar extra

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()

        for mode in [ControllerMode.off, .mirror, .multi] {
            let item = NSMenuItem(title: modeTitle(mode),
                                  action: #selector(statusModeSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            statusModeItems[mode] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open TTR MultiController…",
                                  action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TTR MultiController",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let color: NSColor
        let title: String

        if engine.controlPaused {
            color = .systemYellow
            title = "Paused"
        } else {
            switch engine.mode {
            case .off: color = .systemGray
            case .mirror: color = .systemPurple
            case .multi: color = .systemGreen
            }
            title = modeTitle(engine.mode)
        }

        button.image = Self.dotImage(color: color)
        button.title = title

        for (mode, item) in statusModeItems {
            item.state = (mode == engine.mode) ? .on : .off
        }
    }

    private func modeTitle(_ mode: ControllerMode) -> String {
        switch mode {
        case .off: return "Off"
        case .mirror: return "Mirror"
        case .multi: return "Multi"
        }
    }

    private static func dotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func statusModeSelected(_ sender: NSMenuItem) {
        if let mode = ControllerMode(rawValue: sender.tag) {
            engine.setMode(mode)
        }
    }

    @objc private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About TTR MultiController",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TTR MultiController",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TTR MultiController",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private var aboutWindow: NSWindow?

    @objc private func showAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingController(
                rootView: AboutView(version: Self.appVersion))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = "About TTR MultiController"
            window.isReleasedWhenClosed = false
            window.setContentSize(hosting.view.fittingSize)
            aboutWindow = window
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
