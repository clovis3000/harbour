import Foundation
import HarbourCore

let usage = """
usage: harbour ls [--all] [--json]   what's running (Projects, or everything)
       harbour kill <port|name>      kill a server's tree; a project name kills the project
       harbour port [label]          this project's derived port, e.g. `harbour port api`
       harbour recent [--json]       project servers seen in the last 3 days, not pinned or running
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "ls" : args.removeFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

switch command {
case "ls":
    let all = args.contains("--all")
    let snapshot = await Scanner().scan()
    let servers = all ? snapshot.servers : snapshot.projects
    if args.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(servers), as: UTF8.self))
    } else if servers.isEmpty {
        print("nothing running")
    } else {
        let width = min(36, servers.map(\.name.count).max() ?? 0)
        for s in servers {
            let ports = s.ports.map { String($0) }.joined(separator: ",")
            let badges = s.badges.map(\.rawValue).joined(separator: " ")
            let name = s.name.count > width ? String(s.name.prefix(width - 1)) + "…" : s.name
            print([pad(name, width), pad(ports, 11), pad(Format.bytes(s.footprint), 8),
                   pad(Format.uptime(since: s.start), 8), pad("pid \(s.root)", 10),
                   Format.abbreviate(s.cwd ?? "?"), badges].joined(separator: "  "))
        }
    }

case "kill":
    guard let query = args.first else { fail(usage) }
    let snapshot = await Scanner().scan()
    let targets = snapshot.servers(matching: query)
    guard !targets.isEmpty else { fail("harbour: nothing matches \(query)") }
    if targets.contains(where: { $0.section == .system }), !args.contains("--force") {
        fail("harbour: \(query) is a system server; pass --force to kill it anyway")
    }
    for s in targets { print("killing \(s.name) (\(s.ports.map(String.init).joined(separator: ","))), \(s.tree.count) processes") }
    let survivors = await Killer.kill(targets)
    if !survivors.isEmpty { fail("harbour: could not kill \(survivors.map(String.init).joined(separator: " "))") }

case "port":
    let cwd = FileManager.default.currentDirectoryPath
    var dir = cwd
    while dir != "/", !FileManager.default.fileExists(atPath: dir + "/.git") {
        dir = (dir as NSString).deletingLastPathComponent
    }
    let project = dir == "/" ? cwd : dir
    let snapshot = await Scanner().scan()
    switch Ports.assign(project: project, label: args.first, snapshot: snapshot) {
    case .free(let port):
        print(port)
    case .heldByProject(let port):
        print(port)
        FileHandle.standardError.write(Data("harbour: \(port) is already in use by this project\n".utf8))
    }

case "recent":
    let entries = Recents.load().recent(excluding: .load(), running: await Scanner().scan())
    if args.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    } else if entries.isEmpty {
        print("nothing recent")
    } else {
        let width = min(36, entries.map(\.pin.name.count).max() ?? 0)
        for e in entries {
            print([pad(e.pin.name, width), pad(String(e.pin.port), 6), pad(Format.uptime(since: e.lastSeen) + " ago", 10),
                   pad(e.pin.cwd, 28), e.pin.command].joined(separator: "  "))
        }
    }

case "-h", "--help", "help":
    print(usage)

default:
    fail(usage)
}
