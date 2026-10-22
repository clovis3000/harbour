import AppKit
import SwiftUI

/// Dev affordances, inert unless their environment variables are set.
/// HARBOUR_PREVIEW=1 opens the menu in a plain window; HARBOUR_SNAPSHOT=<path> renders it
/// to a PNG after the first scan (no Screen Recording permission needed) and exits;
/// HARBOUR_SNAPSHOT_DELAY=<s> waits longer (memory history needs 10 s between samples);
/// HARBOUR_FILTER=<text> types into the filter;
/// HARBOUR_EXPAND=<port> opens that server's detail; HARBOUR_START=<pin name> presses
/// that pin's Start after the first scan; HARBOUR_OPEN=1 clicks the real
/// menu bar item, toggles System, and logs the menu window's frame to stderr.
@MainActor
enum Preview {
    static let environment = ProcessInfo.processInfo.environment
    private static var done = false
    private static var started = false

    static func openMenuIfRequested(_ model: HarbourModel) {
        guard environment["HARBOUR_OPEN"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            StatusItem.toggle()
            for step in 0..<8 {
                try? await Task.sleep(for: .seconds(1.5))
                for window in NSApp.windows where window.isVisible && !window.className.contains("StatusBar") {
                    FileHandle.standardError.write(Data("system=\(model.showSystem) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)).prefix(30) } ?? "none") servers=\(model.snapshot?.servers.count ?? -1) open=\(model.isOpen) responder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") \(window.frame)\n".utf8))
                }
                if step == 2 { model.showSystem.toggle() }
            }
            exit(0)
        }
    }

    static func afterRefresh(_ model: HarbourModel) {
        if !started, let name = environment["HARBOUR_START"],
           let pin = model.stoppedPins.first(where: { $0.name == name }) {
            started = true
            model.start(pin)
        }
        if let port = environment["HARBOUR_EXPAND"].flatMap(Int.init),
           let server = model.snapshot?.servers.first(where: { $0.ports.contains(port) }),
           model.expanded != server.id {
            model.toggleDetail(server)
        }
        guard let path = environment["HARBOUR_SNAPSHOT"], !done else { return }
        done = true
        model.isOpen = true  // refresh at the open-menu rate so history fills
        if let filter = environment["HARBOUR_FILTER"] { model.filter = filter }

        Task { @MainActor in
            let delay = environment["HARBOUR_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1
            try? await Task.sleep(for: .seconds(delay))
            let content = MenuView(model: model, scrolls: false)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, environment["HARBOUR_DARK"] == nil ? .light : .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { exit(2) }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
