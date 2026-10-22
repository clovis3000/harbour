import Foundation
import Testing
@testable import HarbourCore

@Test func titleIsExtractedAndDecoded() {
    let html = Data("<html><head><TITLE data-x=1>\n  Notes &amp; atlas </TITLE></head>".utf8)
    #expect(HTML.title(in: html) == "Notes & atlas")
}

@Test func templateTitlesAreIgnored() {
    #expect(HTML.title(in: Data("<title>Directory listing for /</title>".utf8)) == nil)
    #expect(HTML.title(in: Data("<title>Vite + React + TS</title>".utf8)) == nil)
    #expect(HTML.title(in: Data("<p>no title</p>".utf8)) == nil)
}

@Test func derivedPortIsStableAndInRange() {
    let project = NSHomeDirectory() + "/code/myapp"
    let port = Ports.derived(project: project)
    #expect(Ports.range.contains(port))
    #expect(port == Ports.derived(project: project))
    #expect(port != Ports.derived(project: project, label: "api"))
}

@Test func configDefaultsSurvivePartialFiles() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data(#"{"pins": []}"#.utf8))
    #expect(config.roots == ["~/projects"])
}

@Test func uptimeFormatting() {
    let now = Date()
    #expect(Format.uptime(since: now.addingTimeInterval(-90), now: now) == "1m")
    #expect(Format.uptime(since: now.addingTimeInterval(-(41 * 86_400 + 11 * 3600)), now: now) == "41d 11h")
}

@Test func hotkeyParsing() {
    let key = Hotkey("ctrl+option+p")
    #expect(key?.keyCode == 35)
    #expect(key?.modifiers == [.control, .option])
    #expect(Hotkey("Cmd + Shift + Space")?.keyCode == 49)
    #expect(Hotkey("p") == nil)            // no modifier: would eat typing
    #expect(Hotkey("shift+p") == nil)      // shift alone is still typing
    #expect(Hotkey("ctrl+option+F13") == nil)
}

@Test func historyIsSpacedAndWindowed() {
    var history = MemoryHistory()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let server = Server.fixture(id: "1@1", footprint: 100)
    for offset in stride(from: 0.0, through: 30, by: 2) {
        history.record(Snapshot(servers: [server], taken: t0), at: t0.addingTimeInterval(offset))
    }
    #expect(history[server].count == 4)    // 0, 10, 20, 30
    history.record(Snapshot(servers: [server], taken: t0), at: t0.addingTimeInterval(MemoryHistory.window + 25))
    #expect(history[server].count == 2)    // 30 and the new one survive the window
    history.record(Snapshot(servers: [], taken: t0), at: t0.addingTimeInterval(MemoryHistory.window + 60))
    #expect(history[server].isEmpty)       // gone servers are dropped
}

@Test func filterMatchesNamePortAndFolder() {
    let server = Server.fixture(id: "1@1", footprint: 0, name: "Notes atlas", port: 5197, cwd: "/tmp/myapp/web")
    #expect(server.matches("atlas"))
    #expect(server.matches("519"))
    #expect(server.matches("myapp"))
    #expect(!server.matches("8080"))
    #expect(server.matches("  "))
}

@Test func argvBecomesAShellLine() {
    #expect(Shell.line(["/bin/bash", "./dev.sh"]) == "/bin/bash ./dev.sh")
    #expect(Shell.line(["python3", "-m", "http.server", "--directory", "my site"]) == "python3 -m http.server --directory 'my site'")
    #expect(Shell.line(["sh", "-c", "echo 'hi'"]) == #"sh -c 'echo '\''hi'\'''"#)
    #expect(Shell.line(["npm run dev   ", "", ""]) == "npm run dev")   // node rewrote its title over argv
}

@Test func pinRecordsTheTreeRoot() {
    let base = Server.fixture(id: "1@1", footprint: 0, port: 5174, cwd: "/tmp/animise/web")
    let server = Server(id: base.id, host: "local", name: "Animise", root: 445, listeners: [772, 803],
                        sockets: base.sockets, cwd: "/tmp/animise", project: "/tmp/animise",
                        command: ["target/debug/animise-server"], rootCommand: ["/bin/bash", "./dev.sh"],
                        rootCwd: "/tmp/animise", start: .now, tree: [], ancestors: [], footprint: 0,
                        badges: [], section: .projects, primaryPort: 5174, httpPorts: [5174])
    let pin = Pin(server)
    #expect(pin.command == "/bin/bash ./dev.sh")
    #expect(pin.cwd == "/tmp/animise")
}

extension Server {
    static func fixture(id: String, footprint: UInt64, name: String = "x", port: Int = 3000, cwd: String = "/tmp/x") -> Server {
        Server(id: id, host: "local", name: name, root: 1, listeners: [1],
               sockets: [Socket(port: port, family: .v4, address: "127.0.0.1")], cwd: cwd,
               project: (cwd as NSString).deletingLastPathComponent, command: [], rootCommand: [], rootCwd: cwd,
               start: .now, tree: [],
               ancestors: [], footprint: footprint, badges: [], section: .projects,
               primaryPort: port, httpPorts: [port])
    }
}
