import Foundation

extension Server {
    /// Type-to-filter: a substring of the name, project, folder or a port.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return name.lowercased().contains(q)
            || projectName.lowercased().contains(q)
            || (cwd.map { Format.abbreviate($0).lowercased().contains(q) } ?? false)
            || ports.contains { String($0).hasPrefix(q) }
    }
}

/// Footprint over time, per server. Kept in memory only: it starts when Harbour
/// launches and resets when a server restarts (its id includes the start time).
public struct MemoryHistory: Sendable {
    public struct Sample: Sendable, Hashable, Identifiable {
        public let date: Date
        public let bytes: UInt64
        public var id: Date { date }
    }

    /// At least this far apart, so a 2 s refresh while the menu is open doesn't
    /// crowd out the 30 s samples taken while it's closed.
    public static let spacing: TimeInterval = 10
    public static let window: TimeInterval = 2 * 3600

    public private(set) var series: [String: [Sample]] = [:]

    public init() {}

    public mutating func record(_ snapshot: Snapshot, at now: Date = .now) {
        var next: [String: [Sample]] = [:]
        for server in snapshot.servers {
            var samples = series[server.id] ?? []
            if samples.last.map({ now.timeIntervalSince($0.date) >= Self.spacing }) ?? true {
                samples.append(Sample(date: now, bytes: server.footprint))
            }
            samples.removeAll { now.timeIntervalSince($0.date) > Self.window }
            next[server.id] = samples
        }
        series = next
    }

    public subscript(server: Server) -> [Sample] { series[server.id] ?? [] }
}

/// A global shortcut written as "ctrl+option+p". Parsed here; registered by the app.
public struct Hotkey: Sendable, Equatable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers

    public static let `default` = "ctrl+option+p"

    /// ANSI virtual key codes (kVK_ANSI_*), so the core needn't import Carbon.
    private static let keys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "space": 49, "`": 50,
    ]

    public init?(_ string: String) {
        var modifiers: Modifiers = []
        var key: UInt32?
        for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default:
                guard key == nil, let code = Self.keys[part] else { return nil }
                key = code
            }
        }
        // A bare key would swallow ordinary typing system-wide.
        guard let key, !modifiers.subtracting(.shift).isEmpty else { return nil }
        keyCode = key
        self.modifiers = modifiers
    }
}

/// Where "Open in editor" and "Open terminal" go. A command (like `nvim`) runs in the
/// terminal; anything else is treated as an app name for `open -a`.
public enum Tools {
    public static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]

    public static func executable(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func app(_ name: String) -> String? {
        ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications/Utilities"]
            .map { "\($0)/\(name).app" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The configured terminal, else Ghostty if installed, else Terminal.
    public static func terminal(_ config: Config) -> String {
        config.terminal ?? (app("Ghostty") != nil ? "Ghostty" : "Terminal")
    }

    /// The configured editor, else the first of nvim, Zed, Cursor or VS Code found.
    public static func editor(_ config: Config) -> String? {
        if let editor = config.editor { return editor }
        if executable("nvim") != nil { return "nvim" }
        return ["Zed", "Cursor", "Visual Studio Code"].first { app($0) != nil }
    }
}
