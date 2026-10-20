import Foundation

public struct Socket: Sendable, Hashable, Codable {
    public enum Family: String, Sendable, Codable { case v4, v6 }
    public let port: Int
    public let family: Family
    public let address: String

    public var isWildcard: Bool { address == "0.0.0.0" || address == "::" }
    public var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" }
}

public enum Badge: String, Sendable, Codable, CaseIterable {
    case orphan, exposed, doubleBound = "double-bound"
}

public enum Section: String, Sendable, Codable { case projects, system }

public struct ProcessNode: Sendable, Codable, Hashable, Identifiable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let command: [String]
    public let footprint: UInt64
    public let start: Date
    public var id: Int32 { pid }
}

/// One process tree that holds at least one listener: the tree root plus every
/// descendant. A `just dev` that starts vite and an API is one server with two ports.
public struct Server: Sendable, Codable, Identifiable {
    public let id: String
    public let host: String
    public var name: String
    public let root: Int32
    public let listeners: [Int32]
    public let sockets: [Socket]
    public let cwd: String?
    public let project: String
    public let command: [String]
    public let start: Date
    public let tree: [ProcessNode]
    /// Pids above the root, nearest first, ending at launchd. Used for tmux lookup.
    public let ancestors: [Int32]
    public let footprint: UInt64
    public let badges: [Badge]
    public let section: Section
    /// The port a click opens: the one that answered with an HTML title, else the lowest.
    public let primaryPort: Int
    public let httpPorts: [Int]

    public var ports: [Int] { Array(Set(sockets.map(\.port))).sorted() }
    public var isHTTP: Bool { !httpPorts.isEmpty }
    public var url: URL? { isHTTP ? URL(string: "http://localhost:\(primaryPort)") : nil }
    public var projectName: String { (project as NSString).lastPathComponent }
}

public struct Snapshot: Sendable {
    public let servers: [Server]
    public let taken: Date

    public var projects: [Server] { servers.filter { $0.section == .projects } }
    public var system: [Server] { servers.filter { $0.section == .system } }
    public var attention: Int { projects.filter { !$0.badges.isEmpty }.count }

    /// Projects grouped by git root, in first-seen order of the (port-sorted) servers.
    public var projectGroups: [(project: String, servers: [Server])] {
        var order: [String] = []
        var groups: [String: [Server]] = [:]
        for server in projects {
            if groups[server.project] == nil { order.append(server.project) }
            groups[server.project, default: []].append(server)
        }
        return order.map { ($0, groups[$0]!) }
    }

    public func servers(matching query: String) -> [Server] {
        if let port = Int(query) { return servers.filter { $0.ports.contains(port) } }
        let q = query.lowercased()
        let byProject = servers.filter { $0.projectName.lowercased() == q }
        if !byProject.isEmpty { return byProject }
        return servers.filter { $0.name.lowercased() == q }
    }
}

public enum Format {
    public static func bytes(_ n: UInt64) -> String {
        let mb = Double(n) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }

    public static func uptime(since start: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(start))
        let (d, h, m) = (s / 86_400, s % 86_400 / 3600, s % 3600 / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "\(s)s"
    }

    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
