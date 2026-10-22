import AppKit
import Charts
import HarbourCore
import SwiftUI

struct MenuView: View {
    @Bindable var model: HarbourModel
    var scrolls = true
    @State private var confirmReap = false

    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            filterField
            ScrollIf(scrolls) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.snapshot != nil {
                        let (groups, system) = model.filtered
                        let pins = model.filteredPins
                        if groups.isEmpty && pins.isEmpty && (model.filter.isEmpty || system.isEmpty) {
                            Text(model.filter.isEmpty ? "Nothing running" : "No matches")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                        ForEach(groups, id: \.project) { group in
                            if group.servers.count > 1 {
                                VStack(alignment: .leading, spacing: 2) {
                                    ProjectHeader(name: (group.project as NSString).lastPathComponent,
                                                  count: group.servers.count) { model.kill(group.servers) }
                                    ForEach(group.servers) { server in
                                        ServerRow(model: model, server: server)
                                    }
                                }
                                .padding(.bottom, 2)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                                .padding(.vertical, 3)
                            } else {
                                ServerRow(model: model, server: group.servers[0])
                            }
                        }
                        ForEach(pins) { pin in
                            StoppedPinRow(model: model, pin: pin)
                        }
                        if !system.isEmpty {
                            // While filtering, System matches show without a click.
                            let open = model.showSystem || !model.filter.isEmpty
                            // Not a DisclosureGroup: on macOS it adds its own indent and
                            // sizing, and the menu jumped wider when it opened.
                            SectionRow(title: "System", count: system.count, open: open) {
                                model.showSystem.toggle()
                            }
                            .padding(.top, 6)
                            if open {
                                ForEach(system) { server in
                                    ServerRow(model: model, server: server)
                                }
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }

            Divider()
            footer
        }
        .frame(width: 400)
        // Both appearance and key status: on first open the window becomes key before
        // this view subscribes, so the notification alone misses it.
        .onAppear { opened() }
        .onDisappear { model.menuClosed() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            opened()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.menuClosed()
            confirmReap = false
        }
    }

    private func opened() {
        model.isOpen = true
        Task { filterFocused = true }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by name, folder or port", text: $model.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit { model.openFirstMatch() }
                .onExitCommand {
                    if model.filter.isEmpty { StatusItem.toggle() } else { model.filter = "" }
                }
            if let shortcut = model.hotkeyLabel {
                Text(shortcut).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// One type scale with the rows: callout (12 pt) throughout, secondary ink, borderless
    /// controls; the leading edge lines up with the rows' chevrons.
    @ViewBuilder private var footer: some View {
        HStack(spacing: 14) {
            let orphans = model.orphans
            if confirmReap {
                Text("Kill \(orphans.count) orphaned \(orphans.count == 1 ? "server" : "servers")?")
                Spacer()
                Button("Cancel") { confirmReap = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button("Kill", role: .destructive) {
                    model.kill(orphans)
                    confirmReap = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                if !orphans.isEmpty {
                    Button("Reap \(orphans.count) \(orphans.count == 1 ? "orphan" : "orphans")") { confirmReap = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .help(orphans.map(\.name).joined(separator: "\n"))
                }
                Spacer()
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })) {
                    Text("Launch at login").foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
    }
}

/// Sized to its content up to `maxHeight`, then scrolls. A bare ScrollView in a
/// MenuBarExtra sizes to its ideal height, not its content (120 pt with 17 rows).
/// ImageRenderer can't draw a ScrollView's contents, so previews render without one.
private struct ScrollIf<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    init(_ enabled: Bool, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    /// Up to 860 pt, but always leaving 120 pt of the screen's usable height free.
    static var maxHeight: CGFloat { min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 120) }

    var body: some View {
        if enabled {
            ScrollView {
                content.onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.maxHeight))
        } else {
            content
        }
    }
}

/// Group and section headers share the rows' columns: text starts where row names
/// start (after the 12 pt chevron slot), in callout and secondary ink.
private struct ProjectHeader: View {
    let name: String
    let count: Int
    let kill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12, height: 1)
            Text(name).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Button("Kill all \(count)", action: kill)
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.red)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(height: 18)
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.trailing, 44)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A collapsible section that reads as a row: chevron in the rows' chevron column,
/// title in the name column.
private struct SectionRow: View {
    let title: String
    let count: Int
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                // The count sits beside the title: in the port column it read as a port.
                HStack(spacing: 6) {
                    Text(title).foregroundStyle(.secondary)
                    Text(verbatim: String(count)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ServerRow: View {
    let model: HarbourModel
    let server: Server
    @State private var hovering = false

    private var expanded: Bool { model.expanded == server.id }
    private var killing: Bool { model.killing.contains(server.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { model.toggleDetail(server) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).lineLimit(1).truncationMode(.tail)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                BadgeIcons(badges: server.badges)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(server.ports.map(String.init).joined(separator: " · "))
                        .font(.callout.monospacedDigit())
                    Text(Format.bytes(server.footprint))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Pin and kill live in fixed-width slots so hovering never shifts the row.
                let pinned = model.isPinned(server)
                Button { model.togglePin(server) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pinned ? "Unpin" : "Pin")
                .frame(width: 18)
                .opacity(hovering || pinned ? 1 : 0)
                .allowsHitTesting(hovering || pinned)
                if killing {
                    ProgressView().controlSize(.small).frame(width: 18)
                } else if hovering {
                    Button { model.kill([server]) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Kill \(server.tree.count) \(server.tree.count == 1 ? "process" : "processes")")
                    .frame(width: 18)
                } else {
                    Color.clear.frame(width: 18, height: 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { server.isHTTP ? model.open(server) : model.toggleDetail(server) }
            .onHover { hovering = $0 }
            .opacity(killing ? 0.5 : 1)

            if expanded {
                ServerDetail(model: model, server: server)
                    .padding(.leading, 28)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    private var subtitle: String {
        var place = server.projectName
        if let cwd = server.cwd, cwd.hasPrefix(server.project + "/") {
            place += " › " + cwd.dropFirst(server.project.count + 1)
        }
        if server.project == "/" || server.project == NSHomeDirectory() {
            place = server.tree.first?.name ?? "?"
        }
        let uptime = Format.uptime(since: server.start)
        return place == server.name ? uptime : "\(place) · \(uptime)"
    }
}

private struct BadgeIcons: View {
    let badges: [Badge]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges, id: \.self) { badge in
                Image(systemName: symbol(badge))
                    .font(.caption)
                    .foregroundStyle(badge == .orphan ? Color.orange : Color.yellow)
                    .help(help(badge))
            }
        }
    }

    private func symbol(_ badge: Badge) -> String {
        switch badge {
        case .orphan: "moon.zzz.fill"
        case .exposed: "wifi"
        case .doubleBound: "square.on.square"
        }
    }

    private func help(_ badge: Badge) -> String {
        switch badge {
        case .orphan: "Orphan: whatever started this has gone"
        case .exposed: "Exposed: bound to all interfaces, reachable from the network"
        case .doubleBound: "Double-bound: another process holds this port on the other IP family"
        }
    }
}

private struct ServerDetail: View {
    let model: HarbourModel
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Uptime", Format.uptime(since: server.start))
                row("Command", shortCommand, mono: true)
                    .help(server.command.joined(separator: " "))
                GridRow {
                    label("Folder")
                    Button(Format.abbreviate(server.cwd ?? "?")) {
                        if let cwd = server.cwd { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                GridRow {
                    label("Memory")
                    MemorySparkline(samples: model.history[server])
                }
                GridRow {
                    label("Open")
                    HStack(spacing: 10) {
                        if let editor = model.editorName {
                            Button("\(editor)") { model.openEditor(server) }
                                .help("Open the folder in \(editor)")
                        }
                        Button("Terminal") { model.openTerminal(server) }
                            .help("Open a terminal in the folder")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                row("Bound", server.sockets.map { "\($0.family == .v6 ? "[\($0.address)]" : $0.address):\($0.port)" }
                    .joined(separator: "  "), mono: true)
                if let tmux = model.tmux[server.id] {
                    GridRow {
                        label("tmux")
                        HStack {
                            Text(tmux).font(.caption.monospaced())
                            Button("Jump to pane") { Tmux.jump(to: tmux) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(server.tree) { node in
                    HStack(spacing: 6) {
                        Text(node.name).font(.caption.monospaced()).lineLimit(1)
                        Text(verbatim: String(node.pid)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Spacer()
                        Text(Format.bytes(node.footprint)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { model.kill(node: node) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .help("Kill only pid \(node.pid)")
                    }
                    .padding(.leading, CGFloat(depth(node)) * 10)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }

    /// argv[0] as a basename: the full Homebrew Python path is three lines of noise.
    private var shortCommand: String {
        guard let first = server.command.first else { return "?" }
        return ([(first as NSString).lastPathComponent] + server.command.dropFirst()).joined(separator: " ")
    }

    private func depth(_ node: ProcessNode) -> Int {
        let byPid = Dictionary(uniqueKeysWithValues: server.tree.map { ($0.pid, $0) })
        var d = 0
        var current = node
        while current.pid != server.root, let parent = byPid[current.ppid], d < 8 {
            d += 1
            current = parent
        }
        return d
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// A pin whose server isn't running. Clicking it starts the recorded command in tmux
/// and opens the page once it answers, like launching an app from the Dock.
private struct StoppedPinRow: View {
    let model: HarbourModel
    let pin: Pin
    @State private var hovering = false

    private var starting: Bool { model.starting[pin.id] != nil }
    private var failed: Bool { model.failed.contains(pin.id) }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.name).lineLimit(1)
                if failed {
                    HStack(spacing: 4) {
                        Text("didn't start ·").lineLimit(1)
                        Button("show pane") { model.showPane(pin) }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                } else {
                    Text(caption).font(.caption).lineLimit(1)
                }
            }
            Spacer()
            Text(String(pin.port)).font(.callout.monospacedDigit())
            Button { model.unpin(pin) } label: { Image(systemName: "pin.fill") }
                .buttonStyle(.borderless)
                .help("Unpin")
                .frame(width: 18)
            // Start sits in the slot a running row's kill button uses.
            if starting {
                ProgressView().controlSize(.small).frame(width: 18)
            } else if hovering && pin.folderExists {
                Button { model.start(pin) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Start: \(pin.command)")
                    .frame(width: 18)
            } else {
                Color.clear.frame(width: 18, height: 1)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering && pin.folderExists ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if pin.folderExists { model.start(pin) } }
        .onHover { hovering = $0 }
    }

    private var caption: String {
        if !pin.folderExists { return "folder missing · \(pin.cwd)" }
        return starting ? "starting · \(pin.cwd)" : "stopped · \(pin.cwd)"
    }
}

/// Footprint since Harbour started watching this server: one series, a 2 px line, no
/// axes. The caption carries the numbers; hovering reads off a single sample.
private struct MemorySparkline: View {
    let samples: [MemoryHistory.Sample]
    @State private var hovered: MemoryHistory.Sample?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if samples.count >= 2 {
                Chart {
                    ForEach(samples) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Footprint", Double(sample.bytes)))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if let hovered {
                        RuleMark(x: .value("Time", hovered.date))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        PointMark(x: .value("Time", hovered.date), y: .value("Footprint", Double(hovered.bytes)))
                            .symbolSize(30)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: domain)
                .chartLegend(.hidden)
                .frame(height: 32)
                .chartOverlay { proxy in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase, let date: Date = proxy.value(atX: point.x) else {
                                hovered = nil
                                return
                            }
                            hovered = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        }
                }
            }
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// At least 25% of the peak tall, centred on the data: a leak shows as a climb, but
    /// a few KB of churn on a 13 MB server stays flat instead of filling the chart.
    private var domain: ClosedRange<Double> {
        let values = samples.map { Double($0.bytes) }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let span = max(high - low, high * 0.25, 1)
        let mid = (low + high) / 2
        return max(0, mid - span / 2)...(mid + span / 2)
    }

    private var caption: String {
        if let hovered {
            return "\(Format.bytes(hovered.bytes)) at \(hovered.date.formatted(date: .omitted, time: .shortened))"
        }
        guard let last = samples.last else { return "—" }
        guard samples.count >= 2, let first = samples.first else { return "\(Format.bytes(last.bytes)) · history builds every 10 s" }
        let peak = samples.map(\.bytes).max() ?? last.bytes
        return "\(Format.bytes(last.bytes)) now · peak \(Format.bytes(peak)) · over \(Format.uptime(since: first.date, now: last.date))"
    }
}
