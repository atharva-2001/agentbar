// AgentBar: top-center island listing of live Claude Code sessions and the codex runs they dispatched.
// Build: ./build.sh   Self-check: ./build.sh test
import SwiftUI
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let snippetLen = 90

struct Codex: Identifiable {
    var hideKey: String { "c:\(pid):\(name)" }
    let pid: Int32
    let name: String
    let startedAt: Date
    let lastWrite: Date?
    let lastSay: String   // last assistant text in the rollout
    var id: Int32 { pid }
}

struct Session: Identifiable {
    var hideKey: String { "s:\(sid)" }
    let pid: Int32
    let cwd: String
    let busy: Bool
    let lastMsg: String
    let lastAt: Date?
    var lastReply = ""      // Claude's last text reply
    var idle = false        // status "idle": the turn ended
    var waiting: String?    // status "waiting": blocked on you (a permission prompt, a question, a dialog); what it needs
    var statusAt = 0.0      // statusUpdatedAt, changes on every busy/idle flip
    let tty: String?
    let kittyWin: String?
    var codex: [Codex] = []
    var sid = ""
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

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

func lastUserMessage(_ lines: [Substring]) -> (text: String, at: Date?)? {
    for l in lines.reversed() {
        if let d = json(l), let t = userText(d) { return (t, (d["timestamp"] as? String).flatMap(isoFrac.date)) }
    }
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

// Claude's last text reply; tool-only and thinking-only turns are skipped
func lastReply(_ lines: [Substring]) -> String? {
    for l in lines.reversed() {
        guard let d = json(l), d["type"] as? String == "assistant", let msg = d["message"] as? [String: Any],
              let parts = msg["content"] as? [[String: Any]] else { continue }
        let t = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
}

// MARK: scan

// a scan reads only what changed: last message per transcript size, tty and kitty window per pid (fixed for a process's life).
// scan() runs on one serial queue, so the caches need no lock.
var msgCache: [String: (size: UInt64, msg: (text: String, at: Date?)?, reply: String?)] = [:]
var pidCache: [Int32: (tty: String?, kittyWin: String?)] = [:]
let scanQueue = DispatchQueue(label: "scan", qos: .utility)

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
        let term = pidCache[pid] ?? {
            let env = sh(["/bin/ps", "-Eww", "-o", "command=", "-p", "\(pid)"])
            let tty = sh(["/bin/ps", "-o", "tty=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let t = (tty: tty.isEmpty || tty == "??" ? nil : "/dev/\(tty)",
                     kittyWin: env.split(separator: " ").first { $0.hasPrefix("KITTY_WINDOW_ID=") }.map { String($0.dropFirst(16)) })
            pidCache[pid] = t
            return t
        }()
        let size = transcript.flatMap { (try? fm.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.uint64Value } ?? 0
        let msg: (text: String, at: Date?)?
        let reply: String?
        if let c = msgCache[sid], c.size == size { (msg, reply) = (c.msg, c.reply) } else {
            let tail = transcript.map { tailLines($0) } ?? []
            msg = lastUserMessage(tail) ?? transcript.flatMap { lastUserMessage(tailLines($0, bytes: .max)) }
            reply = lastReply(tail)
            msgCache[sid] = (size, msg, reply)
        }
        bySessionId[sid] = pid
        let session = Session(
            pid: pid,
            cwd: (d["cwd"] as? String ?? "").replacingOccurrences(of: home, with: "~"),
            busy: d["status"] as? String == "busy",
            lastMsg: msg?.text ?? "(no message yet)",
            lastAt: msg?.at,
            lastReply: reply ?? "",
            idle: d["status"] as? String == "idle",
            waiting: d["status"] as? String == "waiting" ? (d["needs"] as? String ?? d["waitingFor"] as? String ?? "your input") : nil,
            statusAt: (d["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0,
            tty: term.tty,
            kittyWin: term.kittyWin,
            sid: sid)
        // a session with no typed message yet is not listed, unless it owns a codex run (added below)
        if msg == nil { pending[pid] = session } else { sessions[pid] = session }
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

    // drop cache entries for sessions that ended
    let live = Set(bySessionId.values)
    pidCache = pidCache.filter { live.contains($0.key) }
    msgCache = msgCache.filter { bySessionId[$0.key] != nil }

    // newest message first
    var list = sessions.values.sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
    if !orphans.isEmpty {
        list.append(Session(pid: -1, cwd: "Codex runs with no live session", busy: false, lastMsg: "", lastAt: nil, tty: nil, kittyWin: nil, codex: orphans))
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

// the kitty window you are in, from kitty's remote-control socket (`listen_on unix:/tmp/kitty` in kitty.conf, kitty adds -<pid>).
// nil with no socket: then every finished turn gets a card. The tty route used by focus() cannot read a reply.
func focusedKittyWindow() -> String? {
    let socks = ((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []).filter { $0.hasPrefix("kitty-") }
    for sock in socks {
        if let w = focusedWindow(sh(["/Applications/kitty.app/Contents/MacOS/kitten", "@", "--to", "unix:/tmp/\(sock)", "ls"])) { return w }
    }
    return nil
}

// id of the focused window in `kitten @ ls` output
func focusedWindow(_ ls: String) -> String? {
    guard let osWins = try? JSONSerialization.jsonObject(with: Data(ls.utf8)) as? [[String: Any]] else { return nil }
    for o in osWins { for t in o["tabs"] as? [[String: Any]] ?? [] { for w in t["windows"] as? [[String: Any]] ?? []
        where w["is_focused"] as? Bool == true { return (w["id"] as? NSNumber).map { "\($0)" } } } }
    return nil
}

// MARK: UI

final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var done: Set<String> = []   // session ids whose turn ended and that were not clicked since
    private var prevStatus: [String: Double] = [:]
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        scanQueue.async {
            let s = scan()
            let win = focusedKittyWindow()
            DispatchQueue.main.async {
                let inKitty = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "net.kovidgoyal.kitty"
                withAnimation(spring) { self.sessions = s; self.markDone(s, seenWin: inKitty ? win : nil) }
            }
        }
    }
    // a turn ended or the session is waiting on you: it is idle or waiting now and its status changed since the last scan.
    // Comparing statusUpdatedAt also catches a turn shorter than the 5 s scan. Busy again = you are in it, so it clears.
    // the session in the kitty window you are in gets no card, and its card clears when you switch to it: you have seen it
    func markDone(_ list: [Session], seenWin: String? = nil) {
        for s in list where s.pid > 0 {
            let needsYou = s.idle || s.waiting != nil
            // first scan: a session already waiting on you shows; one already idle does not (it may be days old)
            if needsYou, prevStatus[s.sid].map({ $0 != s.statusAt }) ?? (s.waiting != nil) { done.insert(s.sid) }
            if !needsYou { done.remove(s.sid) }
            prevStatus[s.sid] = s.statusAt
            if seenWin != nil && s.kittyWin == seenWin { done.remove(s.sid) }
        }
        let live = Set(list.map(\.sid))
        done = done.filter(live.contains)
        prevStatus = prevStatus.filter { live.contains($0.key) }
    }
}

// MARK: tokens
// The island is OS chrome, so it uses true black: in dark mode it must merge with the notch.
// Light mode follows the system theme on request. Claude's own orange marks a busy session (it is the ✻ spinner glyph).
struct Palette {
    var isDark: Bool { island == .black }
    let island, text, dim, hover, codex, stall: Color
    var done: Color { isDark ? Color(red: 0.35, green: 0.85, blue: 0.5) : Color(red: 0.1, green: 0.6, blue: 0.3) }
    static let dark = Palette(island: .black, text: Color(white: 0.96), dim: Color(white: 0.6),
                              hover: .white.opacity(0.09), codex: Color(red: 0.48, green: 0.64, blue: 0.97), stall: Color(red: 0.96, green: 0.65, blue: 0.14))
    static let light = Palette(island: Color(white: 0.985), text: Color(white: 0.11), dim: Color(white: 0.45),
                               hover: .black.opacity(0.055), codex: Color(red: 0.16, green: 0.38, blue: 0.85), stall: Color(red: 0.78, green: 0.45, blue: 0.0))
}
// one pastel per project, stable across runs, so the same repo is always the same color.
// A worktree under <repo>/.claude/worktrees/ takes its repo's color. Hues are 36° apart and skip muddy yellow-green.
// ponytail: 10 hues by hash, two projects can share one; assign by order if that bites
let pathHues: [Double] = [0, 25, 45, 140, 170, 195, 215, 245, 280, 320]
func pathColor(_ cwd: String, dark: Bool) -> Color {
    let root = cwd.components(separatedBy: "/.claude/worktrees/")[0]
    let hash = root.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }   // FNV-1a, String.hashValue changes per launch
    let hue = pathHues[Int(hash % UInt32(pathHues.count))] / 360
    // pastel on black; on the light island the same hue darker, or it would wash out
    return dark ? Color(hue: hue, saturation: 0.45, brightness: 0.95) : Color(hue: hue, saturation: 0.65, brightness: 0.6)
}

// kitty's font: it sets no font_family, so it uses its macOS default, Menlo
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Menlo", size: size).weight(weight) }
let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
// the island sits on the screen with the pointer, so these follow that screen
var curScreen: NSScreen? = NSScreen.main
var listCap: CGFloat { (curScreen?.visibleFrame.height ?? 900) - 120 }   // tallest the list can be dragged
var expandedWidth: CGFloat { max(780, notchWidth + 500) }
var pillWidth: CGFloat { notchWidth + 200 }   // room after "busy" before the notch
let flare: CGFloat = 8   // the concave curve where the island meets the top edge of the screen

// notch size from the screen, or a plain 32pt bar on screens without one
var notchHeight: CGFloat { max(curScreen?.safeAreaInsets.top ?? 0, 32) }
var notchWidth: CGFloat {
    guard let s = curScreen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
    return s.frame.width - l.width - r.width
}

// One outline for both states, so opening is the pill stretching, not a panel appearing.
// A neck as wide as the pill runs down the menu bar (the menu bar icons stay clear), then curved shoulders flare out to the body.
// Closed, the body is as wide as the neck and the shoulders collapse to nothing. Every point moves smoothly with the frame.
struct IslandShape: Shape {
    func path(in r: CGRect) -> Path {
        let H = r.height, bx0 = r.minX + flare, bx1 = r.maxX - flare
        let nl = r.midX - pillWidth / 2, nr = r.midX + pillWidth / 2
        let open = min(1, max(0, (H - notchHeight) / 120))
        let rb = 13 + 15 * open                                       // bottom corners round out as it opens
        let s = max(0, min(12, (nl - bx0) / 2, (H - rb - notchHeight) / 2))   // shoulder radius
        let yS = min(notchHeight, H - rb) - s
        var p = Path()
        p.move(to: CGPoint(x: nl - flare, y: 0))
        p.addQuadCurve(to: CGPoint(x: nl, y: flare), control: CGPoint(x: nl, y: 0))
        p.addLine(to: CGPoint(x: nl, y: yS))
        p.addQuadCurve(to: CGPoint(x: nl - s, y: yS + s), control: CGPoint(x: nl, y: yS + s))
        p.addLine(to: CGPoint(x: bx0 + s, y: yS + s))
        p.addQuadCurve(to: CGPoint(x: bx0, y: yS + 2 * s), control: CGPoint(x: bx0, y: yS + s))
        p.addLine(to: CGPoint(x: bx0, y: H - rb))
        p.addQuadCurve(to: CGPoint(x: bx0 + rb, y: H), control: CGPoint(x: bx0, y: H))
        p.addLine(to: CGPoint(x: bx1 - rb, y: H))
        p.addQuadCurve(to: CGPoint(x: bx1, y: H - rb), control: CGPoint(x: bx1, y: H))
        p.addLine(to: CGPoint(x: bx1, y: yS + 2 * s))
        p.addQuadCurve(to: CGPoint(x: bx1 - s, y: yS + s), control: CGPoint(x: bx1, y: yS + s))
        p.addLine(to: CGPoint(x: nr + s, y: yS + s))
        p.addQuadCurve(to: CGPoint(x: nr, y: yS), control: CGPoint(x: nr, y: yS + s))
        p.addLine(to: CGPoint(x: nr, y: flare))
        p.addQuadCurve(to: CGPoint(x: nr + flare, y: 0), control: CGPoint(x: nr, y: 0))
        p.closeSubpath()
        return p
    }
}

// full text of a message, shown when its row is open (a system tooltip needs the app active, which would take focus from kitty)
// hover a row and rest on it: the row itself grows. Your message shows in full,
// then the session's codex runs with what each run said last. No separate box.
struct Row: View {
    let s: Session
    let open: Bool
    var done = false
    let pal: Palette
    let hidden: Set<String>
    let toggleHide: (String) -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(s.pid < 0 ? "" : s.busy ? "✻" : done ? "●" : "○").font(mono(s.busy ? 14 : 11, .bold))
                .foregroundStyle(s.busy ? claudeOrange : done ? (s.waiting != nil ? pal.stall : pal.done) : pal.dim).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                // path on top, so rows from one project read as a group at a glance
                HStack(spacing: 6) {
                    Text(s.cwd).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(s.pid < 0 ? pal.dim : pathColor(s.cwd, dark: pal.isDark))
                    if !s.codex.isEmpty && !open && s.pid > 0 {
                        Label("\(s.codex.count)", systemImage: "gearshape.2").foregroundStyle(pal.codex)
                    }
                    Spacer(minLength: 8)
                    if s.pid > 0 { Text(ago(s.lastAt)).foregroundStyle(pal.dim) }
                }
                .font(mono(12))
                if s.pid > 0 {
                    Text(open ? s.lastMsg : snippet(s.lastMsg)).font(mono(15)).foregroundStyle(pal.text)
                        .lineLimit(open ? nil : 1).fixedSize(horizontal: false, vertical: open)
                }
                // codex runs stay hidden until the row grows (always shown for runs with no live session)
                if open || s.pid < 0 {
                    ForEach(s.codex) { c in
                        let stalled = c.lastWrite.map { Date().timeIntervalSince($0) > 12 * 60 } ?? false   // RUNBOOK_CODEX stall rule
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.2").foregroundStyle(stalled ? pal.stall : pal.codex)
                                Text(c.name).foregroundStyle(pal.text).lineLimit(1)
                                Text(stalled ? "Stalled, no write for \(ago(c.lastWrite))" : "Running \(ago(c.startedAt)), last write \(ago(c.lastWrite)) ago")
                                    .foregroundStyle(stalled ? pal.stall : pal.dim).lineLimit(1)
                            }
                            Text(c.lastSay).foregroundStyle(pal.dim).lineLimit(4).padding(.leading, 22)
                        }
                        .padding(.top, 2)
                        .opacity(hidden.contains(c.hideKey) ? 0.4 : 1)
                        .contextMenu { Button(hidden.contains(c.hideKey) ? "Show this run" : "Hide this run") { toggleHide(c.hideKey) } }
                    }
                }
            }
            .font(mono(13))
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .contentShape(Rectangle())
        .opacity(hidden.contains(s.hideKey) ? 0.4 : 1)
        .contextMenu { if s.pid > 0 { Button(hidden.contains(s.hideKey) ? "Show this session" : "Hide this session") { toggleHide(s.hideKey) } } }
    }
}

struct Island: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: UIState
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Int32?
    @State private var opened: Int32?
    @State private var listHeight: CGFloat = 0
    @State private var rowHeight: CGFloat = 48
    @AppStorage("listMax") private var listMax: Double = 0   // dragged list height, 0 = five rows
    @State private var dragStart: CGFloat?
    @AppStorage("hidden") private var hiddenRaw = ""   // hide keys, newline separated
    @State private var showHidden = false

    func toggleHide(_ key: String) {
        var h = Set(hiddenRaw.split(separator: "\n").map(String.init))
        if h.remove(key) == nil { h.insert(key) }
        withAnimation(spring) { hiddenRaw = h.sorted().joined(separator: "\n") }
    }

    var body: some View {
        VStack(spacing: 6) {
            island
            if !ui.expanded { doneCards }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // finished turns you have not clicked yet, hung under the closed island: your message and Claude's reply, one line each.
    // Click one to jump to its kitty window; right-click to dismiss it. The open list marks them with a green dot.
    @ViewBuilder var doneCards: some View {
        let pal = scheme == .dark ? Palette.dark : Palette.light
        let hidden = Set(hiddenRaw.split(separator: "\n").map(String.init))
        let cards = model.sessions.filter { model.done.contains($0.sid) && !hidden.contains($0.hideKey) }
        if !cards.isEmpty {
            VStack(spacing: 4) {
                ForEach(cards) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("●").foregroundStyle(s.waiting != nil ? pal.stall : pal.done)
                            Text(s.cwd).foregroundStyle(pathColor(s.cwd, dark: pal.isDark)).lineLimit(1).truncationMode(.head)
                        }.font(mono(11))
                        Text("› " + snippet(s.lastMsg)).foregroundStyle(pal.dim).lineLimit(1)
                        if let w = s.waiting {
                            Text("Waiting on you: " + snippet(w)).foregroundStyle(pal.stall).lineLimit(1)
                        } else {
                            Text(snippet(s.lastReply.isEmpty ? "(no text reply)" : s.lastReply)).foregroundStyle(pal.text).lineLimit(1)
                        }
                    }
                    .font(mono(12))
                    .padding(.vertical, 7).padding(.horizontal, 12)
                    .frame(width: 520, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(pal.island))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(scheme == .dark ? .white.opacity(0.12) : .black.opacity(0.1)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.15), radius: 10, y: 4)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(spring) { _ = model.done.remove(s.sid) }; focus(s) }
                    .contextMenu { Button("Dismiss") { withAnimation(spring) { _ = model.done.remove(s.sid) } } }
                    .transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.cardsRect = $0 }
            .onDisappear { ui.cardsRect = .zero }
        }
    }

    @ViewBuilder var island: some View {
        let pal = scheme == .dark ? Palette.dark : Palette.light
        let hidden = Set(hiddenRaw.split(separator: "\n").map(String.init))
        // right-click a row to hide it; hidden rows and runs drop out of the list and the counts
        let visible: [Session] = model.sessions.compactMap { s in
            if hidden.contains(s.hideKey) && !showHidden { return nil }
            var s = s
            if !showHidden { s.codex.removeAll { hidden.contains($0.hideKey) } }
            return s.pid < 0 && s.codex.isEmpty ? nil : s
        }
        let hiddenCount = model.sessions.reduce(0) { n, s in
            n + (hidden.contains(s.hideKey) ? 1 : 0) + s.codex.filter { hidden.contains($0.hideKey) }.count
        }
        let live = visible.filter { $0.pid > 0 && !hidden.contains($0.hideKey) }
        let codex = visible.reduce(0) { $0 + $1.codex.filter { !hidden.contains($0.hideKey) }.count }
        VStack(spacing: 0) {
            // the pill: text in the two "ears" beside the camera notch, the middle stays empty
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(claudeOrange)
                Text("\(live.filter(\.busy).count) busy").contentTransition(.numericText())
                Spacer(minLength: notchWidth)
                if codex > 0 { Image(systemName: "gearshape.2").foregroundStyle(pal.codex); Text("\(codex)") }
                Text("\(live.count)").contentTransition(.numericText())
            }
            .font(mono(13, .bold)).foregroundStyle(pal.text)
            .padding(.horizontal, 14)
            .frame(width: pillWidth, height: notchHeight)

            if ui.expanded {
              let fiveRows = 5 * (rowHeight + 1) + 20
              let cap = listMax > 0 ? CGFloat(listMax) : fiveRows
              VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { s in
                            Row(s: s, open: opened == s.pid, done: model.done.contains(s.sid), pal: pal, hidden: hidden, toggleHide: toggleHide)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if opened != s.pid && s.pid > 0 { rowHeight = $0 } }
                                // hover: a wash of the project's color and a bar of it on the left edge
                                .background(alignment: .leading) {
                                    let on = hovered == s.pid && s.pid > 0
                                    let tint = pathColor(s.cwd, dark: pal.isDark)
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(on ? (pal.isDark ? 0.16 : 0.12) : 0))
                                        Capsule().fill(tint).frame(width: 3).padding(.vertical, 10).padding(.leading, 3).opacity(on ? 1 : 0)
                                    }
                                }
                                .onHover { h in
                                    withAnimation(.easeOut(duration: 0.12)) { hovered = h ? s.pid : (hovered == s.pid ? nil : hovered) }
                                    if !h { if opened == s.pid { withAnimation(.easeOut(duration: 0.2)) { opened = nil } }; return }
                                    // a short rest before the row grows, so sweeping the pointer down the list does not make every row jump
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        if hovered == s.pid { withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { opened = s.pid } }
                                    }
                                }
                                .onTapGesture { if s.pid > 0 { model.done.remove(s.sid); ui.collapse(); focus(s) } }
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                // laid out at the final width from the first frame, so the text never rewraps while the island stretches;
                // the growing outline uncovers it instead
                // five rows tall at most until the handle is dragged, the rest scrolls
                .frame(width: expandedWidth, height: min(listHeight, cap))
                .onHover { if $0 { ui.reachedList = true } }
                // drag handle: pull down for more rows, push up for fewer; the height is remembered
                Capsule().fill(pal.dim.opacity(0.5)).frame(width: 40, height: 4)
                    .frame(width: expandedWidth, height: 16).contentShape(Rectangle())
                    .onHover { h in if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            ui.dragging = true
                            let start = dragStart ?? min(listHeight, cap)
                            dragStart = start
                            listMax = Double(min(max(start + g.translation.height, 2 * (rowHeight + 1) + 20), listCap))
                        }
                        .onEnded { _ in dragStart = nil; ui.endDrag() })
                    .onTapGesture(count: 2) { withAnimation(spring) { listMax = 0 } }   // double-click: back to five rows
                    .overlay(alignment: .leading) {
                        if hiddenCount > 0 {
                            Button(showHidden ? "Hide \(hiddenCount) again" : "\(hiddenCount) hidden, show") { withAnimation(spring) { showHidden.toggle() } }
                                .buttonStyle(.plain).font(mono(11)).foregroundStyle(pal.dim).padding(.leading, 20)
                        }
                    }
              }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -10)).animation(.easeOut(duration: 0.18).delay(0.03)),
                                        removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: ui.expanded ? expandedWidth : pillWidth)
        .padding(.horizontal, flare)
        .background(IslandShape().fill(pal.island).shadow(color: .black.opacity(ui.expanded ? (scheme == .dark ? 0.5 : 0.18) : 0), radius: 24, y: 10))
        .clipShape(IslandShape())
        .overlay(IslandShape().stroke(scheme == .dark ? .clear : .black.opacity(0.1), lineWidth: 1))   // light island needs an edge on a light menu bar
        .contentShape(IslandShape())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.islandRect = $0 }
        .onChange(of: model.sessions.map(\.pid)) {
            // forget hidden keys for sessions and runs that ended, so the stored list does not grow forever
            guard !model.sessions.isEmpty else { return }   // an empty scan must not wipe the list
            let alive = Set(model.sessions.flatMap { [$0.hideKey] + $0.codex.map(\.hideKey) })
            let kept = hiddenRaw.split(separator: "\n").map(String.init).filter(alive.contains)
            if kept.count != hidden.count { hiddenRaw = kept.joined(separator: "\n") }
        }
    }
}

final class UIState: ObservableObject {
    @Published var expanded = false
    private(set) var inside = false
    var islandRect = CGRect.zero   // the island's outline box in window points, top-left origin
    var cardsRect = CGRect.zero    // the finished-turn cards under the closed island, same coordinates
    var dragging = false   // resizing the list: the pointer may leave the island without closing it
    func endDrag() {
        dragging = false
        if !inside { collapse() }
    }
    var reachedList = false   // the pointer went down into the open list, not only across the pill
    func hover(_ h: Bool) {
        guard h != inside else { return }
        inside = h
        if h { if !expanded { expand() }; return }
        // a pointer that only brushed the pill closes it at once; after using the list, a short grace
        // so a pointer that slips past the edge does not slam it shut
        DispatchQueue.main.asyncAfter(deadline: .now() + (reachedList ? 0.08 : 0)) { [self] in if !inside && !dragging { collapse() } }
    }
    func expand() {
        reachedList = false
        withAnimation(spring) { expanded = true }
    }
    func collapse() {
        guard expanded else { return }
        withAnimation(.spring(response: 0.2, dampingFraction: 1)) { expanded = false }   // closing is quicker than opening
    }
}

// the island at the top center of the main screen, around the notch
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
        panel.hasShadow = false   // SwiftUI draws the shadow, so it follows the shape
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // pointer tracking from raw mouse moves, not SwiftUI hover: exit is seen on the very next move, so it closes at once
        panel.acceptsMouseMovedEvents = true
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.track() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in self?.track(); return e }
        place()
        // a display plugged in, unplugged or rearranged: start again on the main screen
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            curScreen = NSScreen.main
            self?.place()
        }
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--expanded") { ui.expand() }
    }

    func track() {
        let m = NSEvent.mouseLocation
        // the pointer moved to another display: the closed island moves there with it
        if !ui.expanded, let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }), s != curScreen {
            curScreen = s
            place()
        }
        let f = panel.frame
        let p = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)   // to window points, top-left origin
        ui.hover(ui.islandRect.insetBy(dx: flare, dy: 0).contains(p))
        // clicks outside the island fall through to whatever is below (menu bar icons, windows)
        let overCards = !ui.expanded && ui.cardsRect.contains(p)   // clickable, but hovering them does not open the island
        panel.ignoresMouseEvents = !(ui.inside || ui.dragging || overCards)
    }

    // The window never changes size: resizing it mid-animation made the island jump for a frame.
    // It is always big enough for the open island and its shadow; the transparent rest ignores the mouse.
    func place() {
        guard let f = curScreen?.frame else { return }
        ui.objectWillChange.send()   // redraw for this screen's notch
        let w = expandedWidth + 2 * flare + 80
        let h = notchHeight + listCap + 60
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
            print("focused kitty window:", focusedKittyWindow() ?? "unknown (no listen_on socket)")
            for s in scan() {
                print(s.busy ? "●" : "○", ago(s.lastAt), s.pid, s.kittyWin ?? "-", snippet(s.lastMsg), "|", s.cwd)
                if let w = s.waiting { print("    ⏸ waiting:", w) }
                if !s.lastReply.isEmpty { print("    ⏺", snippet(s.lastReply)) }
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
        #"{"type":"user","timestamp":"2026-10-09T11:23:46.043Z","message":{"content":[{"type":"text","text":"real ask"}]}}"#,
        #"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"skill body"}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
        #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"assistant","message":{"content":"hi"}}"#,
        "partial garbage {",
        #"{"type":"queue-operation","operation":"remove","content":"old"}"#,
    ]
    precondition(lastUserMessage(lines)?.text == "real ask")
    precondition(lastUserMessage(lines + [#"{"type":"queue-operation","operation":"enqueue","content":"mid turn"}"#])?.text == "mid turn")
    precondition(lastUserMessage(lines + [#"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x"}"#])?.text == "real ask")
    precondition(lastUserMessage(lines)?.at == isoFrac.date(from: "2026-10-09T11:23:46.043Z") && lastUserMessage(lines)?.at != nil)
    precondition(lastCodexSay([#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
                         #"{"type":"event_msg","payload":{"type":"token_count"}}"#]) == "done")
    precondition(lastReply([#"{"type":"assistant","message":{"content":[{"type":"text","text":"the answer"}]}}"#,
                            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
                            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#]) == "the answer")
    precondition(focusedWindow(#"[{"is_focused":true,"tabs":[{"windows":[{"id":3,"is_focused":false},{"id":7,"is_focused":true}]}]}]"#) == "7")
    precondition(focusedWindow(#"[{"tabs":[{"windows":[{"id":3,"is_focused":false}]}]}]"#) == nil && focusedWindow("") == nil)
    precondition(etimeSeconds("00:13") == 13 && etimeSeconds("2-00:00:01") == 172_801 && etimeSeconds("01:02:03") == 3723)
    precondition(snippet(String(repeating: "a", count: snippetLen + 10)).count == snippetLen + 1)
    precondition(snippet("a\nb") == "a b")
    precondition(pathColor("~/x/anc/.claude/worktrees/opt", dark: true) == pathColor("~/x/anc", dark: true))
    print("selftest ok")
}
