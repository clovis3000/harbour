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
    private(set) var tmux: [String: String] = [:]
    var expanded: String?
    var showSystem = Preview.environment["HARBOUR_SYSTEM"] != nil

    var isOpen = false {
        didSet { if isOpen != oldValue { restartLoop() } }
    }

    private let scanner = Scanner()
    private var loop: Task<Void, Never>?

    init() {
        restartLoop()
        Preview.openMenuIfRequested(self)
    }

    /// 2 s while the menu is open, 30 s otherwise; opening it refreshes immediately.
    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: Duration = (self?.isOpen ?? false) ? .seconds(2) : .seconds(30)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let latest = Config.load()
        if latest != config { config = latest }
        snapshot = await scanner.scan(config: config)
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

    func open(_ server: Server) {
        guard let url = server.url else { return }
        NSWorkspace.shared.open(url)
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
