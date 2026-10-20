import AppKit
import SwiftUI

/// Dev affordances, inert unless their environment variables are set.
/// HARBOUR_PREVIEW=1 opens the menu in a plain window; HARBOUR_SNAPSHOT=<path> renders it
/// to a PNG after the first scan (no Screen Recording permission needed) and exits;
/// HARBOUR_EXPAND=<port> opens that server's detail; HARBOUR_OPEN=1 clicks the real
/// menu bar item, toggles System, and logs the menu window's frame to stderr.
@MainActor
enum Preview {
    static let environment = ProcessInfo.processInfo.environment
    private static var done = false

    static func openMenuIfRequested(_ model: HarbourModel) {
        guard environment["HARBOUR_OPEN"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let button = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(statusButton) }.first
            button?.performClick(nil)
            for step in 0..<8 {
                try? await Task.sleep(for: .seconds(1.5))
                for window in NSApp.windows where window.isVisible && !window.className.contains("StatusBar") {
                    FileHandle.standardError.write(Data("system=\(model.showSystem) servers=\(model.snapshot?.servers.count ?? -1) open=\(model.isOpen) \(window.frame)\n".utf8))
                }
                if step == 2 { model.showSystem.toggle() }
            }
            exit(0)
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(statusButton).first
    }

    static func afterRefresh(_ model: HarbourModel) {
        if let port = environment["HARBOUR_EXPAND"].flatMap(Int.init),
           let server = model.snapshot?.servers.first(where: { $0.ports.contains(port) }),
           model.expanded != server.id {
            model.toggleDetail(server)
        }
        guard let path = environment["HARBOUR_SNAPSHOT"], !done else { return }
        done = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
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
