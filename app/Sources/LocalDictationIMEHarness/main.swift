import AppKit
import Carbon
import Foundation
import Network
@testable import LocalDictation
import LocalDictationIME

// Live input-method harness (development only). Launch in the GUI session:
//
//   open -W -n LocalDictationIMEHarness.app --args --out /tmp/ld-ime \
//        [--apps textedit,safari,chrome] [--wav a.wav,b.wav] [--model <coreml dir>]
//
// For each target app it opens a scratch document (never the user's files),
// switches to the Local Dictation input method, and replays (1) a scripted
// revision sequence and (2) live CoreML transcription of the WAVs through the
// real InputMethodInserter. After every update it reads the focused field
// back through the input method and checks it equals
// `prefix + finalized + volatile` exactly. Results: <out>/results.json.

/// Browsers don't expose page text to input methods, so the test page posts
/// its textarea value here on every change ("<page id>\n<value>").
final class PageReporter: @unchecked Sendable {
    static let port: UInt16 = 47654
    private let lock = NSLock()
    private var latest: [String: String] = [:]
    private var listener: NWListener?

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection, buffer: Data())
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let self, let request = String(data: buffer, encoding: .utf8),
               let split = request.range(of: "\r\n\r\n")
            {
                let headers = request[..<split.lowerBound].lowercased()
                let body = String(request[split.upperBound...])
                let length = headers.split(separator: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if body.utf8.count >= length {
                    if let newline = body.firstIndex(of: "\n") {
                        self.lock.withLock { self.latest[String(body[..<newline])] = String(body[body.index(after: newline)...]) }
                    }
                    let reply = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if done { connection.cancel(); return }
            self?.receive(connection, buffer: buffer)
        }
    }

    func value(for page: String) -> String? {
        lock.withLock { latest[page] }
    }
}

struct Target {
    let name: String
    let bundleID: String
    /// Text already in the field before dictation starts.
    let prefix: String
    let document: URL
    /// Set for browser pages that report their own value.
    var pageID: String? = nil
    /// Set for terminals: a raw-mode `cat` writes what the shell receives here.
    var terminalOutput: URL? = nil
}

struct StepFailure: Codable {
    var step: Int
    var expected: String
    var actual: String?
    var note: String
}

struct CaseResult: Codable {
    var app: String
    var name: String
    var steps: Int
    var failures: [StepFailure]
    var clientBundleID: String?
    var finalText: String
    var seconds: Double
}

@MainActor
final class Harness {
    let out: URL
    var results: [CaseResult] = []
    let reporter = PageReporter()
    /// Text committed to each scratch document by earlier sessions.
    var finals: [String: String] = [:]

    func lastFinal(for target: Target) -> String { finals[target.document.path] ?? "" }

    init(out: URL) { self.out = out }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        FileHandle.standardError.write(entry.data(using: .utf8)!)
        let file = out.appendingPathComponent("harness.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func makeTargets(_ names: [String]) throws -> [Target] {
        let dir = out.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var targets: [Target] = []
        for name in names {
            switch name {
            case "textedit":
                let url = dir.appendingPathComponent("textedit-\(UUID().uuidString.prefix(6)).txt")
                try "".write(to: url, atomically: true, encoding: .utf8)
                targets.append(Target(name: name, bundleID: "com.apple.TextEdit", prefix: "", document: url))
            case "safari", "chrome":
                let prefix = "Existing text stays: "
                let page = "\(name)-\(UUID().uuidString.prefix(6))"
                let url = dir.appendingPathComponent("\(page).html")
                let html = """
                <!doctype html><meta charset="utf-8"><title>ld-ime</title>
                <textarea id="t" autofocus style="width:90vw;height:60vh">\(prefix)</textarea>
                <script>
                const t=document.getElementById('t');t.focus();t.setSelectionRange(t.value.length,t.value.length);
                let last=null;
                setInterval(()=>{ if(t.value!==last){ last=t.value;
                  fetch('http://127.0.0.1:\(PageReporter.port)/',{method:'POST',mode:'no-cors',body:'\(page)\\n'+t.value}).catch(()=>{}); } },30);
                </script>
                """
                try html.write(to: url, atomically: true, encoding: .utf8)
                let id = name == "safari" ? "com.apple.Safari" : "com.google.Chrome"
                targets.append(Target(name: name, bundleID: id, prefix: prefix, document: url, pageID: page))
            case "terminal", "warp":
                let stem = "term-\(UUID().uuidString.prefix(6))"
                let output = dir.appendingPathComponent("\(stem).out")
                let script = dir.appendingPathComponent("\(stem).command")
                try "#!/bin/zsh\nstty raw\nexec cat > '\(output.path)'\n".write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                let id = name == "terminal" ? "com.apple.Terminal" : "dev.warp.Warp-Stable"
                targets.append(Target(name: name, bundleID: id, prefix: "", document: script, terminalOutput: output))
            default:
                log("unknown app \(name)")
            }
        }
        return targets
    }

    func open(_ target: Target) async -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            log("\(target.name): not installed")
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([target.document], withApplicationAt: appURL, configuration: config)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID { break }
        }
        try? await Task.sleep(for: .seconds(1.5))  // page load / focus
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        log("\(target.name): frontmost=\(front ?? "?")")
        return front == target.bundleID
    }

    /// Drive one sequence of (finalized, volatile) updates plus a final text.
    func run(
        _ target: Target, name: String,
        updates: [(finalized: String, volatile: String)], final: String,
        expectedBase: String = "",
        pace: Duration = .milliseconds(60)
    ) async {
        let base = expectedBase.isEmpty ? "" : expectedBase + " "
        let started = Date()
        let inserter = InputMethodInserter(attachTimeout: .seconds(4))
        var failures: [StepFailure] = []
        guard inserter.begin(terminal: target.terminalOutput != nil) else {
            failures.append(StepFailure(step: 0, expected: "", actual: nil, note: "begin failed: \(inserter.status)"))
            results.append(CaseResult(app: target.name, name: name, steps: 0, failures: failures,
                                      clientBundleID: nil, finalText: final, seconds: 0))
            return
        }
        // Wait for attach so every step can be verified.
        for _ in 0..<200 where inserter.status == .attaching {
            try? await Task.sleep(for: .milliseconds(20))
        }
        var clientID: String?
        var step = 0
        for update in updates {
            step += 1
            inserter.update(finalized: update.finalized, volatile: update.volatile)
            try? await Task.sleep(for: pace)
            // Terminals show marked text themselves; the shell only receives committed text.
            let expected = target.terminalOutput != nil
                ? (update.finalized.isEmpty ? expectedBase : base + update.finalized)
                : target.prefix + base + Self.shown(update.finalized, update.volatile)
            let (actual, marked) = await readBack(target, expecting: expected)
            if actual != expected {
                failures.append(StepFailure(step: step, expected: expected, actual: actual, note: "marked=\(marked ?? "nil")"))
            }
            if clientID == nil { clientID = inserter.lastReply?.clientBundleID }
        }
        inserter.readBack = target.pageID == nil && target.terminalOutput == nil
        inserter.finish(finalText: final)
        let reply = inserter.lastReply
        let expected = target.prefix + base + final
        var finalText = reply?.documentText
        if target.pageID != nil || target.terminalOutput != nil {
            finalText = await readBack(target, expecting: expected).text
        }
        if let output = target.terminalOutput {
            // End the scratch window's `cat`.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "cat > \(output.path)"]
            try? kill.run()
        }
        if finalText != expected {
            failures.append(StepFailure(step: step + 1, expected: expected, actual: finalText,
                                        note: "after finish; error=\(reply?.error ?? "nil") attached=\(reply?.attached ?? false)"))
        }
        finals[target.document.path] = expectedBase.isEmpty ? final : expectedBase + " " + final
        let result = CaseResult(app: target.name, name: name, steps: updates.count + 1, failures: failures,
                                clientBundleID: clientID, finalText: final, seconds: Date().timeIntervalSince(started))
        log("\(target.name)/\(name): steps=\(result.steps) failures=\(failures.count) client=\(clientID ?? "?")")
        results.append(result)
    }

    /// The field's text: the page's own report for browsers, the input
    /// method's read-back otherwise. Waits briefly for the expected value.
    func readBack(_ target: Target, expecting expected: String) async -> (text: String?, marked: String?) {
        var text: String?
        var marked: String?
        for _ in 0..<20 {
            if let page = target.pageID {
                text = reporter.value(for: page)
            } else if let output = target.terminalOutput {
                text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            } else {
                let reply = InputMethodPortClient.send(InputMethodRequest(op: .probe, session: "", readBack: true))
                text = reply?.documentText
                marked = reply?.marked
            }
            if text == expected { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (text, marked)
    }

    /// What the field should show: finalized, a space, then the marked tail.
    static func shown(_ finalized: String, _ volatile: String) -> String {
        if finalized.isEmpty { return volatile }
        if volatile.isEmpty { return finalized }
        return finalized + " " + volatile
    }

    /// Whole-phrase revisions, a revision that shrinks the text, a
    /// finalization followed by a revised volatile tail, emoji and umlauts.
    static let scripted: [(finalized: String, volatile: String)] = [
        ("", "So"),
        ("", "So I want"),
        ("", "So I want to improve this up"),
        ("", "So I want to improve this app at the moment."),
        ("", "So I want to improve this app at the moment. It is kind of body"),
        ("", "So I want to improve this app at the moment. It is kind of buggy, especially"),
        ("So I want to improve this app at the moment.", "It is kind of buggy, especially on the Mac"),
        ("So I want to improve this app at the moment.", "It's kind of buggy"),
        ("So I want to improve this app at the moment.", "It's kind of buggy, especially on the Mac 👍🏽"),
        ("So I want to improve this app at the moment. It's kind of buggy, especially on the Mac.", "Grüße aus München"),
        ("So I want to improve this app at the moment. It's kind of buggy, especially on the Mac.", ""),
    ]
    static let scriptedFinal = "So I want to improve this app at the moment. It's kind of buggy, especially on the Mac. Grüße aus München."

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: out.appendingPathComponent("results.json"))
    }
}

/// Live CoreML transcription of a WAV into (finalized, volatile) updates.
func transcribeUpdates(wav: URL, engine: ParakeetEngine) async throws -> (updates: [(String, String)], final: String) {
    let data = try Data(contentsOf: wav)
    let pcm = data.subdata(in: 44..<data.count)
    try await engine.beginUtterance()
    var updates: [(String, String)] = []
    let chunk = 3_200
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunk, pcm.count)
        if let snap = try await engine.processAudio(pcm16: pcm.subdata(in: offset..<end)) {
            let view = snap.markedTextView
            updates.append((view.finalized, view.volatile))
        }
        offset = end
    }
    let final = try await engine.finishUtterance()
    return (updates, final)
}

/// Full app path: the real DictationController (CoreML provider, input
/// method route) fed a WAV at real time as if from the microphone.
@MainActor
func runController(_ harness: Harness, target: Target, wav: URL, model: String) async {
    let started = Date()
    var config = AppConfig(provider: .parakeet, parakeetModelPath: model)
    config.useInputMethod = true
    let pcm = (try? Data(contentsOf: wav)).map { $0.subdata(in: 44..<$0.count) } ?? Data()
    let feeder = AudioFeeder(pcm: pcm)
    let deps = DictationController.Dependencies(
        sleep: { try await Task.sleep(for: $0) },
        isSecureEventInputEnabled: { false },
        isAccessibilityTrusted: { true },
        startAudio: { handler in feeder.start(handler) },
        stopAudio: { feeder.stop() },
        presentsSessionUI: false
    )
    let controller = DictationController(config: config, dependencies: deps)
    var finalText: String?
    controller.onFinalTranscript = { finalText = $0 }
    controller.bootstrap()
    for _ in 0..<600 where controller.state != .ready { try? await Task.sleep(for: .milliseconds(100)) }
    guard await harness.open(target) else { return }
    let before = TISCopyCurrentKeyboardInputSource().map { InputMethodInstaller.sourceID($0.takeRetainedValue()) ?? "?" } ?? "?"
    controller.startDictation()
    harness.log("controller: state=\(controller.state.statusTitle) source-before=\(before)")
    while !feeder.finished { try? await Task.sleep(for: .milliseconds(100)) }
    controller.stopDictation()
    for _ in 0..<300 where finalText == nil { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .milliseconds(600))
    let after = TISCopyCurrentKeyboardInputSource().map { InputMethodInstaller.sourceID($0.takeRetainedValue()) ?? "?" } ?? "?"
    var failures: [StepFailure] = []
    let expected = target.prefix + (finalText ?? "<no final>")
    var actual: String?
    if target.pageID != nil || target.terminalOutput != nil {
        actual = await harness.readBack(target, expecting: expected).text
    } else {
        let probe = InputMethodInserter(attachTimeout: .seconds(4))
        _ = probe.begin()
        for _ in 0..<200 where probe.status == .attaching { try? await Task.sleep(for: .milliseconds(20)) }
        actual = await harness.readBack(target, expecting: expected).text
        probe.end(restoreDelay: .zero)
    }
    if actual != expected {
        failures.append(StepFailure(step: 1, expected: expected, actual: actual, note: "controller final"))
    }
    if after != before {
        failures.append(StepFailure(step: 2, expected: before, actual: after, note: "input source not restored"))
    }
    harness.log("\(target.name)/controller: failures=\(failures.count) source-after=\(after) chars=\(finalText?.count ?? -1)")
    harness.results.append(CaseResult(app: target.name, name: "controller-\(wav.deletingPathExtension().lastPathComponent)",
                                      steps: 2, failures: failures, clientBundleID: target.bundleID,
                                      finalText: finalText ?? "", seconds: Date().timeIntervalSince(started)))
    controller.shutdown()
}

/// Feeds PCM16 in 100 ms chunks at real time on a background queue.
final class AudioFeeder: @unchecked Sendable {
    let pcm: Data
    private let lock = NSLock()
    private var running = false
    private var done = false

    init(pcm: Data) { self.pcm = pcm }

    var finished: Bool { lock.withLock { done } }

    func start(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { running = true; done = false }
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < pcm.count, lock.withLock({ running }) {
                let end = min(offset + 3_200, pcm.count)
                handler(pcm.subdata(in: offset..<end))
                offset = end
                Thread.sleep(forTimeInterval: 0.1)
            }
            lock.withLock { done = true }
        }
    }

    func stop() { lock.withLock { running = false } }
}

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let out = URL(fileURLWithPath: arg("--out") ?? "/tmp/ld-ime", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
NSApplication.shared.setActivationPolicy(.accessory)

Task { @MainActor in
    let harness = Harness(out: out)
    do { try harness.reporter.start() } catch { harness.log("page reporter failed: \(error)") }
    harness.log("harness start; IME installed at \(InputMethodInstaller.installedURL.path)")
    let registered = InputMethodInstaller.installAndRegister()
    harness.log("input source registered: \(registered != nil) enabled: \(InputMethodInstaller.isEnabled())")
    guard InputMethodInstaller.isEnabled() else {
        harness.log("input source not enabled — approve it once in System Settings → Keyboard → Input Sources")
        harness.save()
        exit(2)
    }

    var live: [(name: String, updates: [(String, String)], final: String)] = []
    if let wavs = arg("--wav"), let model = arg("--model") {
        let engine = ParakeetEngine()
        do {
            try await engine.load(directory: URL(fileURLWithPath: model, isDirectory: true))
            for path in wavs.split(separator: ",") {
                let url = URL(fileURLWithPath: String(path))
                let result = try await transcribeUpdates(wav: url, engine: engine)
                live.append((url.deletingPathExtension().lastPathComponent, result.updates, result.final))
                harness.log("transcribed \(url.lastPathComponent): \(result.updates.count) updates")
            }
        } catch {
            harness.log("transcription failed: \(error.localizedDescription)")
        }
    }

    let apps = (arg("--apps") ?? "textedit,safari,chrome").split(separator: ",").map(String.init)
    if args.contains("--controller"), let wavs = arg("--wav"), let model = arg("--model") {
        for app in apps {
            for path in wavs.split(separator: ",") {
                if let target = (try? harness.makeTargets([app]))?.first {
                    await runController(harness, target: target, wav: URL(fileURLWithPath: String(path)), model: model)
                }
            }
        }
        harness.save()
        harness.log("harness done: \(harness.results.filter { $0.failures.isEmpty }.count)/\(harness.results.count) cases clean")
        exit(0)
    }
    for target in (try? harness.makeTargets(apps)) ?? [] {
        guard await harness.open(target) else {
            harness.results.append(CaseResult(app: target.name, name: "open", steps: 0,
                                              failures: [StepFailure(step: 0, expected: "", actual: nil, note: "not frontmost")],
                                              clientBundleID: nil, finalText: "", seconds: 0))
            continue
        }
        await harness.run(target, name: "scripted", updates: Harness.scripted, final: Harness.scriptedFinal)
        // Back-to-back sessions: a new dictation right after the last one ended.
        for gap in [50, 150, 300, 500, 700, 800] {
            try? await Task.sleep(for: .milliseconds(gap))
            let base = harness.lastFinal(for: target)
            let words = "rapid \(gap)"
            await harness.run(Target(name: target.name, bundleID: target.bundleID, prefix: target.prefix, document: target.document,
                                     pageID: target.pageID, terminalOutput: target.terminalOutput),
                              name: "rapid-\(gap)ms", updates: [("", words)], final: words,
                              expectedBase: base, pace: .milliseconds(60))
        }
        for item in live {
            // Fresh document per recording so each check starts from the prefix.
            if let fresh = (try? harness.makeTargets([target.name]))?.first, await harness.open(fresh) {
                await harness.run(fresh, name: item.name, updates: item.updates.map { ($0.0, $0.1) }, final: item.final,
                                  pace: .milliseconds(40))
            }
        }
    }
    harness.save()
    harness.log("harness done: \(harness.results.filter { $0.failures.isEmpty }.count)/\(harness.results.count) cases clean")
    try? await Task.sleep(for: .seconds(1))  // let the last input-source restore run
    exit(0)
}
NSApplication.shared.run()
