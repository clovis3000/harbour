import Darwin
import Foundation

public enum Killer {
    /// SIGTERM the whole tree root-first (so a supervisor can't respawn what we just
    /// stopped), wait, then SIGKILL survivors. A pid only counts as a survivor if its
    /// start time still matches, so a reused pid is never shot.
    @discardableResult
    public static func kill(_ servers: [Server], grace: Duration = .seconds(3)) async -> [Int32] {
        let nodes = servers.flatMap(\.tree)
        for node in nodes { Darwin.kill(node.pid, SIGTERM) }

        let deadline = ContinuousClock.now + grace
        var alive = nodes
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            alive = alive.filter(isAlive)
        }
        for node in alive { Darwin.kill(node.pid, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(100))
        return alive.filter(isAlive).map(\.pid)
    }

    public static func kill(pid node: ProcessNode) async -> Bool {
        Darwin.kill(node.pid, SIGTERM)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if !isAlive(node) { return true }
        }
        Darwin.kill(node.pid, SIGKILL)
        try? await Task.sleep(for: .milliseconds(100))
        return !isAlive(node)
    }

    private static func isAlive(_ node: ProcessNode) -> Bool {
        guard let info = Proc.bsd(node.pid) else { return false }
        return abs(info.start.timeIntervalSince(node.start)) < 1
    }
}

public enum Ports {
    public static let range = 20_000..<30_000

    /// The project's port, derived from its git root (relative to $HOME, so it survives
    /// a new machine with the same layout) plus an optional label. Nothing is stored.
    public static func derived(project: String, label: String? = nil) -> Int {
        let key = Format.abbreviate(project) + (label.map { "#" + $0 } ?? "")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return range.lowerBound + Int(hash % UInt64(range.count))
    }

    public enum Assignment: Sendable {
        case free(Int)
        case heldByProject(Int)
    }

    /// Walk forward from the derived port to the first one that is either free or
    /// already this project's.
    public static func assign(project: String, label: String?, snapshot: Snapshot) -> Assignment {
        let start = derived(project: project, label: label)
        for offset in 0..<range.count {
            let port = range.lowerBound + (start - range.lowerBound + offset) % range.count
            let holders = snapshot.servers.filter { $0.ports.contains(port) }
            if !holders.isEmpty {
                if holders.allSatisfy({ $0.project == project }) { return .heldByProject(port) }
                continue
            }
            if isBindable(port) { return .free(port) }
        }
        return .free(start)
    }

    /// Catches listeners Harbour can't see (another uid's processes).
    static func isBindable(_ port: Int) -> Bool {
        bind(AF_INET, port) && bind(AF_INET6, port)
    }

    private static func bind(_ family: Int32, _ port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        } else {
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
    }
}

public enum Tmux {
    /// `session:window.pane` of the tmux pane whose shell is an ancestor of the server.
    /// Shells out, so call it when a detail opens, not on every refresh.
    public static func location(of server: Server) -> String? {
        guard let output = run(["list-panes", "-a", "-F", "#{pane_pid} #{session_name}:#{window_index}.#{pane_index}"]) else { return nil }
        var panes: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]) { panes[pid] = String(parts[1]) }
        }
        return ([server.root] + server.ancestors).lazy.compactMap { panes[$0] }.first
    }

    /// Switch an attached client to the pane, or open Ghostty attached to it.
    public static func jump(to target: String) {
        let session = String(target.prefix { $0 != ":" })
        if let clients = run(["list-clients", "-F", "#{client_name}"]), !clients.isEmpty {
            _ = run(["switch-client", "-t", target])
            _ = run(["select-pane", "-t", target])
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", "Ghostty"]
            try? open.run()
        } else {
            _ = run(["select-window", "-t", target])
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-na", "Ghostty", "--args", "-e", executable ?? "tmux", "attach", "-t", session]
            try? open.run()
        }
    }

    private static let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func run(_ args: [String]) -> String? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
