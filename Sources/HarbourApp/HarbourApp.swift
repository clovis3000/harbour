import AppKit
import HarbourCore
import ServiceManagement
import SwiftUI

@main
struct HarbourApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = HarbourModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            let attention = model.snapshot?.attention ?? 0
            HStack(spacing: 2) {
                Image(systemName: "ferry")
                if attention > 0 { Text("\(attention)") }
            }
        }
        .menuBarExtraStyle(.window)

        // HARBOUR_PREVIEW=1 shows the menu in a plain window, so it can be screenshotted
        // without clicking the menu bar.
        Window("Harbour", id: "preview") {
            MenuView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["HARBOUR_PREVIEW"] == nil ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor @Observable
final class HarbourModel {
    private(set) var snapshot: Snapshot?
    private(set) var config = Config.load()
    private(set) var killing: Set<String> = []
    /// Pin id → when Start was pressed. Cleared when the server appears, or after
    /// `startTimeout`, when the pin moves to `failed` and offers its tmux pane.
    private(set) var starting: [String: Date] = [:]
    private(set) var failed: Set<String> = []
    /// Long enough for a cold `cargo run`.
    private static let startTimeout: TimeInterval = 180
    private(set) var tmux: [String: String] = [:]
    var expanded: String?
    var filter = ""
    private(set) var history = MemoryHistory()
    var showSystem = Preview.environment["HARBOUR_SYSTEM"] != nil

    var isOpen = false {
        didSet { if isOpen != oldValue { restartLoop() } }
    }

    private let scanner = Scanner()
    private var loop: Task<Void, Never>?
    private let hotkey = GlobalHotkey()

    init() {
        restartLoop()
        applyHotkey()
        Preview.openMenuIfRequested(self)
    }

    private func applyHotkey() {
        let setting = config.hotkey ?? Hotkey.default
        hotkey.register(setting == "off" ? nil : Hotkey(setting)) { StatusItem.toggle() }
    }

    /// 2 s while the menu is open or a pin is starting, 30 s otherwise; opening it
    /// refreshes immediately.
    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let fast = (self?.isOpen ?? false) || !(self?.starting.isEmpty ?? true)
                let interval: Duration = fast ? .seconds(2) : .seconds(30)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let latest = Config.load()
        if latest != config {
            let hotkeyChanged = latest.hotkey != config.hotkey
            config = latest
            if hotkeyChanged { applyHotkey() }
        }
        let fresh = await scanner.scan(config: config)
        snapshot = fresh
        history.record(fresh)
        settleStarts(fresh)
        Preview.afterRefresh(self)
    }

    var orphans: [Server] { snapshot?.projects.filter { $0.badges.contains(.orphan) } ?? [] }

    var stoppedPins: [Pin] {
        guard let snapshot else { return [] }
        return config.pins.filter { pin in !snapshot.servers.contains(where: pin.matches) }
    }

    func isPinned(_ server: Server) -> Bool { config.isPinned(server) }

    func togglePin(_ server: Server) {
        config.togglePin(server)
        try? config.save()
    }

    func unpin(_ pin: Pin) {
        config.pins.removeAll { $0 == pin }
        try? config.save()
    }

    /// Runs the pin's command in tmux; the browser opens once the server answers HTTP.
    func start(_ pin: Pin) {
        guard starting[pin.id] == nil else { return }
        failed.remove(pin.id)
        starting[pin.id] = .now
        restartLoop()
        Task.detached {
            let ok = Tmux.start(pin)
            await MainActor.run {
                guard !ok else { return }
                self.starting[pin.id] = nil
                self.failed.insert(pin.id)
            }
        }
    }

    /// The pin's tmux window, where a start that never came up left its output.
    func showPane(_ pin: Pin) {
        Task.detached {
            if let target = Tmux.window(named: pin.name) { Tmux.jump(to: target) }
        }
    }

    private func settleStarts(_ snapshot: Snapshot) {
        failed.subtract(config.pins.filter { pin in snapshot.servers.contains(where: pin.matches) }.map(\.id))
        for (id, since) in starting {
            guard let pin = config.pins.first(where: { $0.id == id }) else {
                starting[id] = nil
                continue
            }
            if let server = snapshot.servers.first(where: pin.matches) {
                // A port can bind a scan before it answers HTTP; give it a few more.
                guard server.isHTTP || Date.now.timeIntervalSince(since) > 10 else { continue }
                starting[id] = nil
                open(server)
            } else if Date.now.timeIntervalSince(since) > Self.startTimeout {
                starting[id] = nil
                failed.insert(id)
            }
        }
    }

    func open(_ server: Server) {
        guard let url = server.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Clearing on close means the hotkey always opens to the whole list.
    func menuClosed() {
        isOpen = false
        filter = ""
    }

    var filtered: (projects: [(project: String, servers: [Server])], system: [Server]) {
        guard let snapshot else { return ([], []) }
        let groups = snapshot.projectGroups.compactMap { group -> (project: String, servers: [Server])? in
            let servers = group.servers.filter { $0.matches(filter) }
            return servers.isEmpty ? nil : (group.project, servers)
        }
        return (groups, snapshot.system.filter { $0.matches(filter) })
    }

    var filteredPins: [Pin] {
        stoppedPins.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Return in the filter field opens the first match that serves HTTP, else starts
    /// the first stopped pin that matches.
    func openFirstMatch() {
        let (projects, system) = filtered
        if let server = (projects.flatMap(\.servers) + system).first(where: \.isHTTP) {
            open(server)
        } else if let pin = filteredPins.first(where: \.folderExists) {
            start(pin)
        }
    }

    func openEditor(_ server: Server) {
        Launch.editor(server.cwd ?? server.project, config: config)
    }

    func openTerminal(_ server: Server) {
        Launch.terminal(server.cwd ?? server.project, config: config)
    }

    var editorName: String? { Tools.editor(config) }

    /// "⌃⌥P" for the filter field's hint; nil when the hotkey is off or unparseable.
    var hotkeyLabel: String? {
        let setting = config.hotkey ?? Hotkey.default
        guard setting != "off", let key = Hotkey(setting), let letter = setting.split(separator: "+").last else { return nil }
        var label = ""
        if key.modifiers.contains(.control) { label += "⌃" }
        if key.modifiers.contains(.option) { label += "⌥" }
        if key.modifiers.contains(.shift) { label += "⇧" }
        if key.modifiers.contains(.command) { label += "⌘" }
        return label + letter.trimmingCharacters(in: .whitespaces).uppercased()
    }

    func kill(_ servers: [Server]) {
        killing.formUnion(servers.map(\.id))
        Task {
            await Killer.kill(servers)
            await refresh()
            killing.subtract(servers.map(\.id))
        }
    }

    func kill(node: ProcessNode) {
        Task {
            _ = await Killer.kill(pid: node)
            await refresh()
        }
    }

    func toggleDetail(_ server: Server) {
        expanded = expanded == server.id ? nil : server.id
        guard expanded != nil else { return }
        Task.detached {
            let location = Tmux.location(of: server)
            await MainActor.run { self.tmux[server.id] = location }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}
