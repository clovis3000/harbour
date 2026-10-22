import Darwin
import Foundation

/// Builds a `Snapshot` from live OS state. Holds only caches keyed by (pid, start time),
/// so a reused pid can never inherit a dead process's title or launchd status.
public actor Scanner {
    private struct Key: Hashable { let pid: pid_t; let start: Date }
    private struct Probe { let title: String?; let isHTTP: Bool; let at: Date }

    private var probes: [String: Probe] = [:]           // "\(pid)@\(start):\(port)"
    private var launchdJobs: Set<pid_t> = []
    private var launchdChecked: Set<Key> = []
    private var argsCache: [Key: [String]] = [:]
    private var gitRoots: [String: String] = [:]

    private let uid = getuid()

    public init() {}

    public func scan(config: Config = .load()) async -> Snapshot {
        let table = Dictionary(Proc.allPids().compactMap(Proc.bsd).map { ($0.pid, $0) },
                               uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: table.values, by: \.ppid)

        var sockets: [pid_t: [Socket]] = [:]
        for info in table.values where info.uid == uid {
            let s = Proc.listeners(info.pid)
            if !s.isEmpty { sockets[info.pid] = s }
        }

        // Group listening processes by tree root.
        var byRoot: [pid_t: [pid_t]] = [:]
        for pid in sockets.keys {
            byRoot[treeRoot(of: pid, ports: Set(sockets[pid]!.map(\.port)), table: table, sockets: sockets),
                   default: []].append(pid)
        }

        let unclassified = byRoot.keys.compactMap { table[$0] }
            .filter { $0.ppid == 1 && !launchdChecked.contains(Key(pid: $0.pid, start: $0.start)) }
        if !unclassified.isEmpty {
            launchdJobs = Self.launchctlPids()
            launchdChecked.formUnion(unclassified.map { Key(pid: $0.pid, start: $0.start) })
        }

        let roots = config.roots.map(Format.expand)
        var drafts: [Draft] = []
        for (root, listeners) in byRoot {
            guard let rootInfo = table[root] else { continue }
            let listeners = listeners.sorted()
            let socks = listeners.flatMap { sockets[$0]! }
            let tree = descendants(of: root, children: children)
            let nodes = tree.compactMap { table[$0] }.map { info in
                ProcessNode(pid: info.pid, ppid: info.ppid, name: displayName(info),
                            command: arguments(info), footprint: Proc.footprint(info.pid), start: info.start)
            }
            let cwd = Proc.cwd(listeners[0]) ?? Proc.cwd(root)
            let project = cwd.map(gitRoot) ?? "/"
            let inRoots = cwd.map { c in roots.contains { c == $0 || c.hasPrefix($0 + "/") } } ?? false
            drafts.append(Draft(
                root: rootInfo, listeners: listeners, sockets: socks, cwd: cwd, project: project,
                command: arguments(table[listeners[0]] ?? rootInfo),
                rootCommand: arguments(rootInfo), rootCwd: Proc.cwd(root),
                tree: nodes, ancestors: ancestors(of: root, table: table),
                section: inRoots ? .projects : .system,
                orphan: rootInfo.ppid == 1 && !isLaunchdJob(rootInfo)))
        }

        await probeHTTP(drafts.filter { $0.section == .projects })

        let portOwners = Dictionary(grouping: drafts.flatMap { d in d.sockets.map { ($0.port, d.root.pid) } },
                                    by: \.0).mapValues { Set($0.map(\.1)) }
        let servers = Self.ordered(drafts.map { finish($0, portOwners: portOwners, config: config) })

        let live = Set(table.keys)
        probes = probes.filter { live.contains(pid_t($0.key.prefix { $0 != "@" }) ?? -1) }
        argsCache = argsCache.filter { live.contains($0.key.pid) }
        launchdChecked = launchdChecked.filter { live.contains($0.pid) }
        return Snapshot(servers: servers, taken: .now)
    }

    /// A total order, so rows never swap between refreshes (two servers on one port used
    /// to tie and trade places every scan). Sorted by what the reader sees: a project
    /// group by its header, a lone server by its own name; then port, then pid.
    private static func ordered(_ servers: [Server]) -> [Server] {
        let counts = Dictionary(grouping: servers.filter { $0.section == .projects }, by: \.project).mapValues(\.count)
        func key(_ s: Server) -> (Int, String, String, Int, Int32) {
            let label = (counts[s.project] ?? 0) > 1 ? s.projectName : s.name
            return (s.section == .projects ? 0 : 1, label.lowercased(), s.project, s.ports.first ?? 0, s.root)
        }
        return servers.sorted { key($0) < key($1) }
    }

    // MARK: - Tree root

    private static let shells: Set = ["zsh", "bash", "sh", "fish", "dash", "login"]
    private static let terminals: Set = ["tmux", "screen", "ghostty", "Terminal", "iTerm2", "sshd", "launchd"]

    /// Walk up from a listener, stopping below the first parent that marks the edge of
    /// the project: launchd, an interactive shell, a terminal, an app bundle, or a
    /// different server. Errs toward stopping early, because a short tree kills less.
    private func treeRoot(of pid: pid_t, ports: Set<Int>, table: [pid_t: Proc.BSD],
                          sockets: [pid_t: [Socket]]) -> pid_t {
        var current = pid
        while let info = table[current], info.ppid > 1, let parent = table[info.ppid], parent.uid == uid {
            let name = displayName(parent)
            if Self.terminals.contains(name) { break }
            if Self.shells.contains(name), !isCommandShell(parent) { break }
            if let path = Proc.path(parent.pid), isAppPath(path) { break }
            if let theirs = sockets[parent.pid], Set(theirs.map(\.port)).isDisjoint(with: ports) { break }
            current = parent.pid
        }
        return current
    }

    /// `sh -c …` and `bash script.sh` are plumbing (`just` and `npm` run every recipe
    /// line through one); a bare `zsh` or `-zsh -l` is a human's terminal.
    private func isCommandShell(_ info: Proc.BSD) -> Bool {
        arguments(info).dropFirst().contains { arg in
            !arg.hasPrefix("-") || (!arg.hasPrefix("--") && arg.dropFirst().contains("c"))
        }
    }

    private func isAppPath(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix("/System/")
            || path.contains("/Library/Application Support/")
    }

    private func descendants(of root: pid_t, children: [pid_t: [Proc.BSD]]) -> [pid_t] {
        var out: [pid_t] = []
        var stack = [root]
        while let pid = stack.popLast() {
            out.append(pid)
            stack.append(contentsOf: (children[pid] ?? []).map(\.pid).sorted(by: >))
        }
        return out
    }

    private func ancestors(of pid: pid_t, table: [pid_t: Proc.BSD]) -> [Int32] {
        var out: [Int32] = []
        var current = table[pid]?.ppid ?? 0
        while current > 0, out.count < 64 {
            out.append(current)
            current = table[current]?.ppid ?? 0
        }
        return out
    }

    // MARK: - Identity

    private func displayName(_ info: Proc.BSD) -> String {
        let comm = info.comm.hasPrefix("-") ? String(info.comm.dropFirst()) : info.comm
        return (comm as NSString).lastPathComponent
    }

    private func arguments(_ info: Proc.BSD) -> [String] {
        let key = Key(pid: info.pid, start: info.start)
        if let cached = argsCache[key] { return cached }
        let args = Proc.arguments(info.pid)
        argsCache[key] = args
        return args
    }

    private func gitRoot(_ cwd: String) -> String {
        if let cached = gitRoots[cwd] { return cached }
        var dir = cwd
        var found = cwd
        while dir != "/", !dir.isEmpty {
            if FileManager.default.fileExists(atPath: dir + "/.git") { found = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        gitRoots[cwd] = found
        return found
    }

    /// LaunchAgents (your own services, Homebrew's Postgres) also have ppid 1 and are meant to; an
    /// orphan is a ppid-1 process launchd didn't start. `launchctl` runs only when a
    /// ppid-1 root appears that hasn't been classified yet.
    private func isLaunchdJob(_ info: Proc.BSD) -> Bool {
        launchdJobs.contains(info.pid)
    }

    private static func launchctlPids() -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { pid_t($0.split(separator: "\t").first ?? "") })
    }

    // MARK: - HTTP

    private func probeKey(_ d: Draft, _ port: Int) -> String { "\(d.root.pid)@\(d.root.start.timeIntervalSince1970):\(port)" }

    private func probeHTTP(_ drafts: [Draft]) async {
        let retry: TimeInterval = 30
        var wanted: [(String, Socket)] = []
        for d in drafts {
            var seen = Set<Int>()
            for s in d.sockets where seen.insert(s.port).inserted {
                let key = probeKey(d, s.port)
                if let p = probes[key], p.isHTTP || Date.now.timeIntervalSince(p.at) < retry { continue }
                wanted.append((key, s))
            }
        }
        let results = await withTaskGroup(of: (String, Probe).self) { group in
            for (key, socket) in wanted {
                group.addTask { (key, await Self.probe(socket)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        probes.merge(results) { _, new in new }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 1
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    private static func probe(_ socket: Socket) async -> Probe {
        let host = socket.family == .v6 ? "[::1]" : "127.0.0.1"
        guard let url = URL(string: "http://\(host):\(socket.port)/") else { return Probe(title: nil, isHTTP: false, at: .now) }
        do {
            let (data, response) = try await session.data(from: url)
            guard response is HTTPURLResponse else { return Probe(title: nil, isHTTP: false, at: .now) }
            return Probe(title: HTML.title(in: data), isHTTP: true, at: .now)
        } catch {
            return Probe(title: nil, isHTTP: false, at: .now)
        }
    }

    // MARK: - Assembly

    private struct Draft {
        let root: Proc.BSD
        let listeners: [pid_t]
        let sockets: [Socket]
        let cwd: String?
        let project: String
        let command: [String]
        let rootCommand: [String]
        let rootCwd: String?
        let tree: [ProcessNode]
        let ancestors: [Int32]
        let section: Section
        let orphan: Bool
    }

    private func finish(_ d: Draft, portOwners: [Int: Set<pid_t>], config: Config) -> Server {
        let ports = Array(Set(d.sockets.map(\.port))).sorted()
        let probed = ports.compactMap { port in probes[probeKey(d, port)].map { (port, $0) } }
        let httpPorts = probed.filter { $0.1.isHTTP }.map(\.0)
        let titled = probed.first { $0.1.title != nil }
        let primary = titled?.0 ?? httpPorts.first ?? ports.first ?? 0

        var badges: [Badge] = []
        if d.section == .projects {
            if d.orphan { badges.append(.orphan) }
            if d.sockets.contains(where: \.isWildcard) { badges.append(.exposed) }
            if ports.contains(where: { (portOwners[$0]?.count ?? 0) > 1 }) { badges.append(.doubleBound) }
        }

        let name = ports.lazy.compactMap { config.nameOverride(project: d.project, port: $0) }.first
            ?? titled?.1.title
            ?? binaryName(d.command)
            ?? d.cwd.flatMap(Manifest.name)
            ?? folderName(cwd: d.cwd, project: d.project, fallback: displayName(d.root))

        return Server(
            id: "\(d.root.pid)@\(Int(d.root.start.timeIntervalSince1970))", host: "local", name: name,
            root: d.root.pid, listeners: d.listeners, sockets: d.sockets, cwd: d.cwd, project: d.project,
            command: d.command, rootCommand: d.rootCommand, rootCwd: d.rootCwd, start: d.root.start, tree: d.tree, ancestors: d.ancestors,
            footprint: d.tree.reduce(0) { $0 + $1.footprint }, badges: badges, section: d.section,
            primaryPort: primary, httpPorts: httpPorts)
    }

    private static let interpreters = ["python", "node", "bun", "deno", "ruby", "php", "java", "perl",
                                       "uv", "npm", "npx", "pnpm", "yarn", "sh", "bash", "zsh", "dotnet", "beam"]

    /// A compiled server's own name (`api-server`, `render-worker`) says more than its folder's
    /// manifest; an interpreter's (`Python`, `node`) says nothing.
    private func binaryName(_ command: [String]) -> String? {
        guard let first = command.first else { return nil }
        let name = (first as NSString).lastPathComponent
        let lower = name.lowercased()
        return name.isEmpty || Self.interpreters.contains(where: lower.hasPrefix) ? nil : name
    }

    private func folderName(cwd: String?, project: String, fallback: String) -> String {
        guard let cwd, project != "/", project != NSHomeDirectory() else { return fallback }
        let base = (project as NSString).lastPathComponent
        guard cwd.count > project.count, cwd.hasPrefix(project + "/") else { return base }
        return "\(base) › \(cwd.dropFirst(project.count + 1))"
    }
}

enum HTML {
    /// Titles that name the template, not the project.
    private static let generic = ["directory listing for", "vite + ", "vite app", "react app", "index of /"]

    static func title(in data: Data) -> String? {
        let text = String(decoding: data.prefix(65_536), as: UTF8.self)
        guard let open = text.range(of: "<title", options: .caseInsensitive),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let end = text.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<text.endIndex)
        else { return nil }
        let raw = text[close.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = raw.lowercased()
        guard !raw.isEmpty, !generic.contains(where: lower.hasPrefix) else { return nil }
        return raw
    }
}

enum Manifest {
    static func name(cwd: String) -> String? {
        if let data = FileManager.default.contents(atPath: cwd + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        if let data = FileManager.default.contents(atPath: cwd + "/Cargo.toml") {
            var inPackage = false
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") { inPackage = t == "[package]" }
                else if inPackage, t.hasPrefix("name"), let eq = t.firstIndex(of: "=") {
                    return t[t.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
        }
        return nil
    }
}
