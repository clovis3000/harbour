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
    public var command: String

    public var id: String { "\(project):\(port)" }

    init(_ server: Server) {
        name = server.name
        project = Format.abbreviate(server.project)
        cwd = Format.abbreviate(server.cwd ?? server.project)
        port = server.primaryPort
        command = server.command.joined(separator: " ")
    }

    public func matches(_ server: Server) -> Bool {
        Format.expand(project) == server.project && server.ports.contains(port)
    }

    public var folderExists: Bool {
        FileManager.default.fileExists(atPath: Format.expand(cwd))
    }
}
