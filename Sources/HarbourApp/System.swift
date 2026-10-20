import AppKit
import Carbon.HIToolbox
import HarbourCore

/// A global shortcut through Carbon's RegisterEventHotKey: the one API that needs no
/// Accessibility permission, because it only ever sees its own registered chord.
@MainActor
final class GlobalHotkey {
    private static var action: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    func register(_ hotkey: Hotkey?, action: @escaping () -> Void) {
        unregister()
        guard let hotkey else { return }
        Self.action = action
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalHotkey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }
        var carbon: UInt32 = 0
        if hotkey.modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if hotkey.modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if hotkey.modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if hotkey.modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x4852_4252), id: 1)  // 'HRBR'
        let status = RegisterEventHotKey(hotkey.keyCode, carbon, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            // Usually another app owns the chord; set "hotkey" in the config to pick another.
            FileHandle.standardError.write(Data("harbour: hotkey not registered (OSStatus \(status))\n".utf8))
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

@MainActor
enum StatusItem {
    /// Opens (or closes) the MenuBarExtra as if its icon were clicked. The app is
    /// activated first so the menu window becomes key and the filter field gets typing.
    static func toggle() {
        NSApp.activate()
        button?.performClick(nil)
    }

    private static var button: NSStatusBarButton? {
        NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    private static func find(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(find).first
    }
}

/// Opening a folder in the editor or a terminal, per `Tools`' detection or the config.
enum Launch {
    static func editor(_ folder: String, config: Config) {
        guard let editor = Tools.editor(config) else { return }
        if let path = Tools.executable(editor) {
            inTerminal(folder, command: [path, "."], config: config)
        } else {
            open(["-a", editor, folder])
        }
    }

    static func terminal(_ folder: String, config: Config) {
        inTerminal(folder, command: nil, config: config)
    }

    private static func inTerminal(_ folder: String, command: [String]?, config: Config) {
        let terminal = Tools.terminal(config)
        if terminal == "Ghostty" {
            var args = ["-na", "Ghostty", "--args", "--working-directory=\(folder)"]
            if let command { args += ["-e"] + command }
            open(args)
        } else {
            // Terminal.app can open a folder but not run a command without scripting it.
            open(["-a", terminal, folder])
        }
    }

    private static func open(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()
    }
}
