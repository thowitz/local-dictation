import AppKit
import Foundation
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

struct Target {
    let name: String
    let bundleID: String
    /// Text already in the field before dictation starts.
    let prefix: String
    let document: URL
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
                let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).html")
                let html = """
                <!doctype html><meta charset="utf-8"><title>ld-ime</title>
                <textarea id="t" autofocus style="width:90vw;height:60vh">\(prefix)</textarea>
                <script>const t=document.getElementById('t');t.focus();t.setSelectionRange(t.value.length,t.value.length);</script>
                """
                try html.write(to: url, atomically: true, encoding: .utf8)
                let id = name == "safari" ? "com.apple.Safari" : "com.google.Chrome"
                targets.append(Target(name: name, bundleID: id, prefix: prefix, document: url))
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
        pace: Duration = .milliseconds(60)
    ) async {
        let started = Date()
        let inserter = InputMethodInserter(attachTimeout: .seconds(4))
        var failures: [StepFailure] = []
        guard inserter.begin() else {
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
            let reply = InputMethodPortClient.send(InputMethodRequest(op: .probe, session: "", readBack: true))
            clientID = reply?.clientBundleID ?? clientID
            let expected = target.prefix + Self.shown(update.finalized, update.volatile)
            if reply?.documentText != expected {
                failures.append(StepFailure(step: step, expected: expected, actual: reply?.documentText,
                                            note: "marked=\(reply?.marked ?? "nil")"))
            }
        }
        inserter.finish(finalText: final)
        try? await Task.sleep(for: .milliseconds(400))
        // The session ended and the source was restored: re-attach to read back.
        let probe = InputMethodInserter(attachTimeout: .seconds(4))
        _ = probe.begin()
        for _ in 0..<200 where probe.status == .attaching {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let reply = InputMethodPortClient.send(InputMethodRequest(op: .probe, session: "", readBack: true))
        probe.end(restoreDelay: .zero)
        let expected = target.prefix + final
        if reply?.documentText != expected {
            failures.append(StepFailure(step: step + 1, expected: expected, actual: reply?.documentText, note: "after finish"))
        }
        let result = CaseResult(app: target.name, name: name, steps: updates.count + 1, failures: failures,
                                clientBundleID: clientID, finalText: final, seconds: Date().timeIntervalSince(started))
        log("\(target.name)/\(name): steps=\(result.steps) failures=\(failures.count) client=\(clientID ?? "?")")
        results.append(result)
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
    for target in (try? harness.makeTargets(apps)) ?? [] {
        guard await harness.open(target) else {
            harness.results.append(CaseResult(app: target.name, name: "open", steps: 0,
                                              failures: [StepFailure(step: 0, expected: "", actual: nil, note: "not frontmost")],
                                              clientBundleID: nil, finalText: "", seconds: 0))
            continue
        }
        await harness.run(target, name: "scripted", updates: Harness.scripted, final: Harness.scriptedFinal)
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
    exit(0)
}
NSApplication.shared.run()
