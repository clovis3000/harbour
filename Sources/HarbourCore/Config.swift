import Foundation

/// The only stored state: what the user created on purpose. Everything about what is
/// running is derived from the OS on each scan, so there is no registry to go stale.
public struct Config: Codable, Sendable, Equatable {
    public var roots: [String] = ["~/projects"]
    /// "<project path>:<port>" → display name.
    public var names: [String: String] = [:]
    public var pins: [Pin] = []
    /// A command run in the terminal (`nvim`) or an app name (`Zed`). Auto-detected when unset.
    public var editor: String?
    /// An app name (`Ghostty`, `Terminal`). Auto-detected when unset.
    public var terminal: String?
    /// Opens the menu from anywhere, e.g. "ctrl+option+p". `"off"` disables it.
    public var hotkey: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? Config().roots
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        editor = try c.decodeIfPresent(String.self, forKey: .editor)
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
    }

    public static let url = URL(fileURLWithPath: Format.expand("~/.config/harbour/config.json"))

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    public func nameOverride(project: String, port: Int) -> String? {
        names["\(Format.abbreviate(project)):\(port)"]
    }

    public func isPinned(_ server: Server) -> Bool {
        pins.contains { $0.matches(server) }
    }

    public mutating func togglePin(_ server: Server) {
        if let i = pins.firstIndex(where: { $0.matches(server) }) {
            pins.remove(at: i)
        } else {
            pins.append(Pin(server))
        }
    }
}

public struct Pin: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var project: String
    public var cwd: String
    public var port: Int
    /// A shell line typed into the pin's tmux window by Start. Editable: `just dev` works.
    public var command: String

    public var id: String { "\(project):\(port)" }

    init(_ server: Server) {
        name = server.name
        project = Format.abbreviate(server.project)
        let argv = Shell.portable(server.rootCommand.isEmpty ? server.command : server.rootCommand)
        cwd = Format.abbreviate(Self.launchFolder(argv, from: server.rootCwd ?? server.cwd ?? server.project))
        port = server.primaryPort
        command = Shell.line(argv)
    }

    /// The folder to re-run `argv` from. Usually the process's own, but a script that
    /// changes into its folder after starting (`python disegno/serve.py`) reports that
    /// folder instead, so walk up until the command's relative paths exist again.
    static func launchFolder(_ argv: [String], from cwd: String) -> String {
        let paths = argv.dropFirst().filter { $0.contains("/") && !$0.hasPrefix("/") && !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return cwd }
        var dir = cwd
        while dir != "/", !dir.isEmpty {
            if paths.allSatisfy({ FileManager.default.fileExists(atPath: dir + "/" + $0) }) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return cwd
    }

    public func matches(_ server: Server) -> Bool {
        Format.expand(project) == server.project && server.ports.contains(port)
    }

    public var folderExists: Bool {
        FileManager.default.fileExists(atPath: Format.expand(cwd))
    }
}

/// Project servers seen running, for the Recent section. Each entry is a dated
/// observation ("seen at 15:40"), which stays true after the fact and only ages out, so
/// unlike a registry of what's running it can't go stale. Kept apart from the config,
/// which holds only what the user wrote on purpose.
public struct Recents: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var pin: Pin
        public var lastSeen: Date
        public var id: String { pin.id }
    }

    public static let window: TimeInterval = 3 * 86_400
    public static let shown = 8
    /// A minute is plenty for "3h ago", and it keeps a 2 s refresh from rewriting the file.
    static let resolution: TimeInterval = 60

    public private(set) var entries: [Entry] = []

    public init() {}

    public static let url = URL(fileURLWithPath: Format.expand("~/.local/state/harbour/history.json"))

    public static func load() -> Recents {
        guard let data = try? Data(contentsOf: url) else { return Recents() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Recents.self, from: data)) ?? Recents()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    /// Notes every Projects server as seen now, and drops entries past the window.
    /// Returns whether anything changed enough to be worth writing.
    @discardableResult
    public mutating func record(_ snapshot: Snapshot, at now: Date = .now) -> Bool {
        var changed = false
        for server in snapshot.projects where !(server.rootCommand.isEmpty && server.command.isEmpty) {
            let pin = Pin(server)
            if let i = entries.firstIndex(where: { $0.id == pin.id }) {
                if entries[i].pin != pin || now.timeIntervalSince(entries[i].lastSeen) >= Self.resolution {
                    entries[i] = Entry(pin: pin, lastSeen: now)
                    changed = true
                }
            } else {
                entries.append(Entry(pin: pin, lastSeen: now))
                changed = true
            }
        }
        let count = entries.count
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > Self.window }
        return changed || entries.count != count
    }

    public mutating func forget(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Newest first: seen within the window, not pinned, not running now.
    public func recent(excluding config: Config, running snapshot: Snapshot, now: Date = .now) -> [Entry] {
        Array(entries
            .filter { entry in
                now.timeIntervalSince(entry.lastSeen) <= Self.window
                    && !config.pins.contains { $0.id == entry.id }
                    && !snapshot.servers.contains(where: entry.pin.matches)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(Self.shown))
    }
}
