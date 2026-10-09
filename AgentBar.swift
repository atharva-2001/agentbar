// AgentBar: top-center island listing of live Claude Code sessions and the codex runs they dispatched.
// Build: ./build.sh   Self-check: ./build.sh test
import SwiftUI
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let snippetLen = 90

struct Codex: Identifiable {
    let pid: Int32
    let name: String
    let startedAt: Date
    let lastWrite: Date?
    let lastSay: String   // last assistant text in the rollout
    var id: Int32 { pid }
}

struct Session: Identifiable {
    let pid: Int32
    let cwd: String
    let busy: Bool
    let lastMsg: String
    let tty: String?
    let kittyWin: String?
    var codex: [Codex] = []
    var id: Int32 { pid }
}

// MARK: shell + file helpers

func sh(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// last `bytes` of a file as lines; the first line may be partial, callers skip lines that fail to parse
func tailLines(_ path: String, bytes: UInt64 = 512 * 1024) -> [Substring] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > bytes ? size - bytes : 0)
    return String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
}

func json(_ line: Substring) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
}

// MARK: parsing (pure, covered by selftest)

// the user's own typed text from one transcript line, nil for tool results, meta lines and command echoes
func userText(_ d: [String: Any]) -> String? {
    // a message typed while a turn runs is stored as a queue operation
    var text: String?
    if d["type"] as? String == "queue-operation" {
        guard d["operation"] as? String == "enqueue" else { return nil }
        text = d["content"] as? String
    } else {
    guard d["type"] as? String == "user", d["isMeta"] as? Bool != true,
          let msg = d["message"] as? [String: Any] else { return nil }
    if let s = msg["content"] as? String { text = s }
    else if let parts = msg["content"] as? [[String: Any]], !parts.contains(where: { $0["type"] as? String == "tool_result" }) {
        text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
    }
    }
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
    return t
}

func lastUserMessage(_ lines: [Substring]) -> String? {
    for l in lines.reversed() { if let d = json(l), let t = userText(d) { return t } }
    return nil
}

func lastCodexSay(_ lines: [Substring]) -> String? {
    for l in lines.reversed() {
        guard let d = json(l), let p = d["payload"] as? [String: Any],
              p["type"] as? String == "message", p["role"] as? String == "assistant",
              let parts = p["content"] as? [[String: Any]] else { continue }
        let t = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        if !t.isEmpty { return t }
    }
    return nil
}

func snippet(_ s: String) -> String {
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count > snippetLen ? flat.prefix(snippetLen) + "…" : flat
}

// ps etime: [[dd-]hh:]mm:ss
func etimeSeconds(_ e: String) -> Double {
    let dayParts = e.split(separator: "-")
    let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
    var hms = (dayParts.last ?? "").split(separator: ":").map { Double($0) ?? 0 }
    while hms.count < 3 { hms.insert(0, at: 0) }
    return ((days * 24 + hms[0]) * 60 + hms[1]) * 60 + hms[2]
}

func ago(_ d: Date?) -> String {
    guard let d else { return "?" }
    let s = Int(Date().timeIntervalSince(d))
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h\(s % 3600 / 60)m"
}

// MARK: scan

func scan() -> [Session] {
    let fm = FileManager.default
    let sessDir = "\(home)/.claude/sessions"
    var bySessionId: [String: Int32] = [:]
    var sessions: [Int32: Session] = [:]
    var pending: [Int32: Session] = [:]

    for f in (try? fm.contentsOfDirectory(atPath: sessDir)) ?? [] where f.hasSuffix(".json") {
        guard let data = fm.contents(atPath: "\(sessDir)/\(f)"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (d["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0,
              let sid = d["sessionId"] as? String else { continue }
        // ponytail: glob over every project dir per session, cheap at ~20 sessions
        let transcript = ((try? fm.contentsOfDirectory(atPath: "\(home)/.claude/projects")) ?? [])
            .map { "\(home)/.claude/projects/\($0)/\(sid).jsonl" }.first { fm.fileExists(atPath: $0) }
        let env = sh(["/bin/ps", "-Eww", "-o", "command=", "-p", "\(pid)"])
        let tty = sh(["/bin/ps", "-o", "tty=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        bySessionId[sid] = pid
        // a session with no typed message yet is not listed, unless it owns a codex run (added below)
        guard let msg = transcript.flatMap({ lastUserMessage(tailLines($0)) ?? lastUserMessage(tailLines($0, bytes: .max)) }) else {
            pending[pid] = Session(pid: pid, cwd: (d["cwd"] as? String ?? "").replacingOccurrences(of: home, with: "~"), busy: false,
                                   lastMsg: "(no message yet)", tty: tty.isEmpty || tty == "??" ? nil : "/dev/\(tty)", kittyWin: nil)
            continue
        }
        sessions[pid] = Session(
            pid: pid,
            cwd: (d["cwd"] as? String ?? "").replacingOccurrences(of: home, with: "~"),
            busy: d["status"] as? String == "busy",
            lastMsg: msg,
            tty: tty.isEmpty || tty == "??" ? nil : "/dev/\(tty)",
            kittyWin: env.split(separator: " ").first { $0.hasPrefix("KITTY_WINDOW_ID=") }.map { String($0.dropFirst(16)) })
    }

    // codex exec runs: owner is a claude ancestor, or the session recorded by the dispatcher in ~/.codex/run-owners/<pid>
    var parents: [Int32: Int32] = [:]
    var runs: [(pid: Int32, start: Date, args: String)] = []
    for line in sh(["/bin/ps", "-axo", "pid=,ppid=,etime=,command="]).split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
        parents[pid] = ppid
        let cmd = String(f[3])
        if let r = cmd.range(of: #"^\S*/codex\s+exec\b"#, options: .regularExpression) {
            runs.append((pid, Date().addingTimeInterval(-etimeSeconds(String(f[2]))), String(cmd[r.upperBound...])))
        }
    }
    let codexPids = Set(runs.map(\.pid))
    var orphans: [Codex] = []
    for r in runs where !codexPids.contains(parents[r.pid] ?? 0) {   // skip a native codex under the node shim twice
        var owner: Int32?
        var name: String?
        var p: Int32? = r.pid
        while let cur = p, cur > 1, owner == nil {
            if sessions[cur] == nil, let p = pending.removeValue(forKey: cur) { sessions[cur] = p }
            if sessions[cur] != nil { owner = cur }
            else if let s = try? String(contentsOfFile: "\(home)/.codex/run-owners/\(cur)", encoding: .utf8) {
                let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
                if parts.count >= 2 { name = String(parts[1]) }
                owner = parts.first.flatMap { bySessionId[String($0)] }
                if let o = owner, sessions[o] == nil { sessions[o] = pending.removeValue(forKey: o) }
                if owner == nil { break }
            }
            p = parents[cur]
        }
        let rollout = sh(["/usr/sbin/lsof", "-a", "-p", "\(r.pid)", "-Fn"]).split(separator: "\n")
            .first { $0.contains("/.codex/sessions/") && $0.hasSuffix(".jsonl") }.map { String($0.dropFirst()) }
        let mtime = rollout.flatMap { try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let report = r.args.range(of: #"--output-last-message\s+\S+"#, options: .regularExpression)
            .map { String(r.args[$0]).split(separator: "/").last.map(String.init) ?? "" }
        let run = Codex(pid: r.pid, name: name ?? report ?? "codex \(r.pid)", startedAt: r.start, lastWrite: mtime,
                        lastSay: rollout.flatMap { lastCodexSay(tailLines($0)) } ?? "(no output yet)")
        if let o = owner { sessions[o]?.codex.append(run) } else { orphans.append(run) }
    }

    var list = sessions.values.sorted { ($0.busy ? 0 : 1, $0.pid) < ($1.busy ? 0 : 1, $1.pid) }
    if !orphans.isEmpty {
        list.append(Session(pid: -1, cwd: "codex runs with no live owner", busy: false, lastMsg: "", tty: nil, kittyWin: nil, codex: orphans))
    }
    return list
}

// MARK: focus

// kitty has allow_remote_control but no listen_on socket, so send the remote-control code through the session's own tty.
// no_response keeps kitty from typing a reply into the claude prompt.
func focus(_ s: Session) {
    if let tty = s.tty, let win = s.kittyWin, let h = FileHandle(forWritingAtPath: tty) {
        let cmd = #"{"cmd":"focus-window","version":[0,46,2],"no_response":true,"payload":{"match":"id:\#(win)"}}"#
        h.write(Data("\u{1b}P@kitty-cmd\(cmd)\u{1b}\\".utf8))
        try? h.close()
    }
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.kovidgoyal.kitty").map {
        NSWorkspace.shared.openApplication(at: $0, configuration: .init())
    }
}

// MARK: UI

final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let s = scan()
            DispatchQueue.main.async { withAnimation(spring) { self.sessions = s } }
        }
    }
}

// hover the bubble icon: the full text opens under the row, inside the island
// (a system tooltip needs the app active, which would take focus from kitty)
struct Bubble: View {
    let text: String
    @Binding var open: String?
    let key: String
    var body: some View {
        Image(systemName: open == key ? "text.bubble.fill" : "text.bubble").foregroundStyle(.secondary)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { open = h ? key : (open == key ? nil : open) } }
    }
}

struct FullText: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct Row: View {
    let s: Session
    @State private var open: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if s.pid > 0 {
                HStack(spacing: 6) {
                    Circle().fill(s.busy ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                    Text(snippet(s.lastMsg)).lineLimit(1)
                    Spacer()
                    // hover only this icon for the full message, so the list does not spray tooltips
                    Bubble(text: s.lastMsg, open: $open, key: "msg")
                }
                Text(s.cwd).font(.caption2).foregroundStyle(.secondary).padding(.leading, 14)
                if open == "msg" { FullText(text: s.lastMsg) }
            } else {
                Text(s.cwd).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(s.codex) { c in
                let stalled = c.lastWrite.map { Date().timeIntervalSince($0) > 12 * 60 } ?? false   // RUNBOOK_CODEX stall rule
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2").foregroundStyle(stalled ? .orange : .blue)
                    Text(c.name).lineLimit(1)
                    Text("run \(ago(c.startedAt)) · write \(ago(c.lastWrite))\(stalled ? " · STALLED" : "")")
                        .font(.caption2).foregroundStyle(stalled ? .orange : .secondary)
                    Spacer()
                    Bubble(text: c.lastSay, open: $open, key: "\(c.pid)")
                }
                .font(.callout).padding(.leading, 14)
                if open == "\(c.pid)" { FullText(text: c.lastSay).padding(.leading, 14) }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
let listCap: CGFloat = 560
let expandedWidth: CGFloat = max(720, notchWidth + 440)
let pillWidth: CGFloat = notchWidth + 160

struct Island: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: UIState
    @State private var hovered: Int32?

    var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.sessions) { s in
                Row(s: s)
                    .background(RoundedRectangle(cornerRadius: 10).fill(hovered == s.pid && s.pid > 0 ? Color.white.opacity(0.12) : .clear))
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h ? s.pid : nil } }
                    .onTapGesture { if s.pid > 0 { ui.collapse(); focus(s) } }
            }
        }
    }

    var body: some View {
        let live = model.sessions.filter { $0.pid > 0 }
        let codex = model.sessions.reduce(0) { $0 + $1.codex.count }
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // text sits in the two "ears" beside the camera notch, the middle stays empty
                HStack(spacing: 6) {
                    Text("✻").foregroundStyle(.orange)
                    Text("\(live.filter(\.busy).count) busy").contentTransition(.numericText())
                    Spacer(minLength: notchWidth)
                    Text("\(live.count)").contentTransition(.numericText())
                    if codex > 0 { Image(systemName: "gearshape.2").foregroundStyle(.blue); Text("\(codex)") }
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: notchHeight)
                .contentShape(Rectangle())
                if ui.expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        // short list sits as is, a long one scrolls
                        ViewThatFits(in: .vertical) {
                            list
                            ScrollView { list }.scrollIndicators(.never)
                        }
                        .frame(maxHeight: listCap)
                        HStack {
                            Spacer()
                            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 8)
                    }
                    .padding([.horizontal, .bottom], 8)
                    .environment(\.colorScheme, .dark)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(spring.delay(0.05)),
                                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
            }
            .frame(width: ui.expanded ? expandedWidth : pillWidth)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: ui.expanded ? 24 : 14, bottomTrailingRadius: ui.expanded ? 24 : 14).fill(.black))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: ui.expanded ? 24 : 14, bottomTrailingRadius: ui.expanded ? 24 : 14))
            .shadow(color: .black.opacity(ui.expanded ? 0.35 : 0), radius: 18, y: 8)
            .onHover { ui.hover($0) }   // pointer on the island opens it, pointer off closes it
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// notch size from the screen, or a plain 32pt bar on screens without one
let notchHeight: CGFloat = max(NSScreen.main?.safeAreaInsets.top ?? 0, 32)
let notchWidth: CGFloat = {
    guard let s = NSScreen.main, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
    return s.frame.width - l.width - r.width
}()

final class UIState: ObservableObject {
    @Published var expanded = false
    var resize: (Bool) -> Void = { _ in }
    private var inside = false
    func hover(_ h: Bool) {
        inside = h
        if h { if !expanded { expand() } ; return }
        // short grace so a pointer that slips past the edge does not slam it shut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in if !inside { collapse() } }
    }
    // grow the window first, then spring the island open inside it
    func expand() {
        resize(true)
        withAnimation(spring) { expanded = true }
    }
    // spring the island shut, then shrink the window once the animation is done
    func collapse() {
        guard expanded else { return }
        withAnimation(spring) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in if !expanded { resize(false) } }
    }
}

// black pill at the top center of the main screen, over the notch, like the Dynamic Island
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let ui = UIState()
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = Host(rootView: Island(model: model, ui: ui))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // SwiftUI draws the shadow, so it follows the spring
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ui.resize = { [weak self] open in self?.place(open: open) }
        place(open: false)
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--expanded") { ui.expand() }
    }

    func place(open: Bool) {
        guard let f = NSScreen.main?.frame else { return }
        // open: room for the island plus its shadow, closed: exactly the pill
        let w = open ? expandedWidth + 60 : pillWidth
        let h = open ? notchHeight + listCap + 90 : notchHeight
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { false } }   // never take focus from kitty
// the panel is never key, so take every click instead of eating it
final class Host: NSHostingView<Island> { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { selftest(); return }
        if CommandLine.arguments.contains("--dump") {
            for s in scan() {
                print(s.busy ? "●" : "○", s.pid, s.kittyWin ?? "-", snippet(s.lastMsg), "|", s.cwd)
                for c in s.codex { print("    ⚙", c.pid, c.name, "write", ago(c.lastWrite)) }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: selftest

func selftest() {
    let lines: [Substring] = [
        #"{"type":"user","message":{"content":"first ask"}}"#,
        #"{"type":"user","message":{"content":[{"type":"text","text":"real ask"}]}}"#,
        #"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"skill body"}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
        #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"assistant","message":{"content":"hi"}}"#,
        "partial garbage {",
        #"{"type":"queue-operation","operation":"remove","content":"old"}"#,
    ]
    precondition(lastUserMessage(lines) == "real ask")
    precondition(lastUserMessage(lines + [#"{"type":"queue-operation","operation":"enqueue","content":"mid turn"}"#]) == "mid turn")
    precondition(lastUserMessage(lines + [#"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x"}"#]) == "real ask")
    precondition(lastCodexSay([#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
                         #"{"type":"event_msg","payload":{"type":"token_count"}}"#]) == "done")
    precondition(etimeSeconds("00:13") == 13 && etimeSeconds("2-00:00:01") == 172_801 && etimeSeconds("01:02:03") == 3723)
    precondition(snippet(String(repeating: "a", count: snippetLen + 10)).count == snippetLen + 1)
    precondition(snippet("a\nb") == "a b")
    print("selftest ok")
}
