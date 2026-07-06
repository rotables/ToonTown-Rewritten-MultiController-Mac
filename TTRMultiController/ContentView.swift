import SwiftUI
import CoreGraphics

struct AboutView: View {
    let version: String

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
            Text("TTR MultiController")
                .font(.title3.weight(.bold))
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 8) {
                Text("Multitoon controller for Toontown Rewritten on macOS.")
                Text("Unofficial fan-made tool — not affiliated with, endorsed by, or supported by Toontown Rewritten.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 340)
    }
}

struct ContentView: View {
    @ObservedObject var model: ControllerViewModel

    var body: some View {
        Form {
            statusSection
            if !model.tapRunning { permissionSection }
            toonsSection
            keybindsSection
            optionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 700)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    Text("Off").tag(ControllerMode.off)
                    Text("Mirror").tag(ControllerMode.mirror)
                    Text("Multi").tag(ControllerMode.multi)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.vertical, 2)
        }
    }

    private var statusTitle: String {
        guard model.mode != .off else { return model.mode.label }
        if model.controlPaused { return "\(model.mode.label) · PAUSED" }
        if model.chatMode { return "\(model.mode.label) · CHAT" }
        return model.mode.label
    }

    private var statusColor: Color {
        guard model.mode != .off else { return .gray }
        if model.controlPaused { return .yellow }
        if model.chatMode { return .orange }
        switch model.mode {
        case .off: return .gray
        case .mirror: return .purple
        case .multi: return .green
        }
    }

    private var statusDetail: String {
        if model.mode != .off && model.controlPaused {
            return "Another app is focused — keys behave normally until you click a game window"
        }
        if model.mode != .off && model.chatMode {
            return "Chatting — keys aren't translated · Return sends · Esc cancels"
        }
        switch model.mode {
        case .off:
            return "Press \(VK.name(for: model.toggleKey)) in the game to cycle Off → Mirror → Multi"
        case .mirror:
            return "Your input goes to every assigned toon · Return to chat on all"
        case .multi:
            return "Group 1 & Group 2 keybinds drive their groups simultaneously · Return to chat"
        }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Accessibility permission is required to control the game")
                Spacer()
                Button("Grant…") { model.retryTapOrOpenSettings() }
            }
        }
    }

    // MARK: - Toons

    private var toonsSection: some View {
        Section("Toon windows") {
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 8) {
                    Picker(ControllerViewModel.slotTitles[i], selection: slotBinding(i)) {
                        Text("None").tag(CGWindowID?.none)
                        ForEach(slotOptions(i), id: \.windowID) { window in
                            Text(window.displayName).tag(CGWindowID?.some(window.windowID))
                        }
                    }
                    Button {
                        model.togglePick(slot: i)
                    } label: {
                        if model.pickingSlot == i {
                            Text("Click a game window…")
                        } else {
                            Image(systemName: "scope")
                        }
                    }
                    .help("Click this, then click a Toontown window to assign it")
                }
            }
            HStack {
                Button("Refresh") { model.refreshDiscovered() }
                Button("Auto-fill") { model.autoFill() }
                Spacer()
                Text(discoveryText)
                    .font(.caption)
                    .foregroundStyle(model.pickingSlot != nil ? Color.orange : Color.secondary)
            }
        }
    }

    private var discoveryText: String {
        if model.pickingSlot != nil {
            return "Click a Toontown window to assign it — any other click cancels"
        }
        let n = model.discovered.count
        return n == 1 ? "1 Toontown window found" : "\(n) Toontown windows found"
    }

    private func slotBinding(_ index: Int) -> Binding<CGWindowID?> {
        Binding(
            get: { model.slots[index]?.windowID },
            set: { model.assign(windowID: $0, toSlot: index) }
        )
    }

    /// Discovered windows, plus the assigned one if it fell out of discovery.
    private func slotOptions(_ index: Int) -> [ToonWindow] {
        var options = model.discovered
        if let assigned = model.slots[index],
           !options.contains(where: { $0.windowID == assigned.windowID }) {
            options.append(assigned)
        }
        return options
    }

    // MARK: - Keybinds

    private var keybindsSection: some View {
        Section("Keybinds · Multi mode") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Group 1 · TTR controls").font(.subheadline.weight(.semibold))
                    Text("Group 2").font(.subheadline.weight(.semibold))
                }
                ForEach(GameAction.allCases, id: \.self) { action in
                    GridRow {
                        Text(action.label)
                            .frame(minWidth: 64, alignment: .leading)
                        bindButton(.left, action)
                        bindButton(.right, action)
                    }
                }
            }
            .padding(.vertical, 4)
            Text("Group 1's keys must match your in-game TTR controls — they're exactly what gets sent to the game. Group 2's keys can be anything; they're translated into Group 1's. Changed your controls in TTR? Update the Group 1 column to match.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bindButton(_ side: ToonSide, _ action: GameAction) -> some View {
        let id = "\(side.rawValue)-\(action.rawValue)"
        let isCapturing = model.capturingBindID == id
        return Button {
            if isCapturing {
                model.cancelCapture()
            } else {
                model.beginCapture(id: id) { code in
                    model.setBind(side: side, action: action, code: code)
                }
            }
        } label: {
            Text(isCapturing ? "Press a key…" : VK.name(for: model.bind(side: side, action: action)))
                .frame(minWidth: 100)
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        Section("Options") {
            HStack {
                Text("Activation key")
                Spacer()
                Button {
                    if model.capturingBindID == "toggle" {
                        model.cancelCapture()
                    } else {
                        model.beginCapture(id: "toggle") { model.setToggleKey($0) }
                    }
                } label: {
                    Text(model.capturingBindID == "toggle"
                         ? "Press a key…" : VK.name(for: model.toggleKey))
                        .frame(minWidth: 100)
                }
            }
            Toggle("Smart focus — only control while a game window is focused",
                   isOn: Binding(get: { model.smartFocus },
                                 set: { model.setSmartFocus($0) }))
        }
    }
}
