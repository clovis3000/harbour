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
    #expect(config.roots == ["~/code", "~/research"])
}

@Test func uptimeFormatting() {
    let now = Date()
    #expect(Format.uptime(since: now.addingTimeInterval(-90), now: now) == "1m")
    #expect(Format.uptime(since: now.addingTimeInterval(-(41 * 86_400 + 11 * 3600)), now: now) == "41d 11h")
}
