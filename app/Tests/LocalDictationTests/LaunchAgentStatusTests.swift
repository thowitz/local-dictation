import Foundation
import Testing
@testable import LocalDictation

@Suite("LaunchAgentStatus")
@MainActor
struct LaunchAgentStatusTests {
    private func writeValidPlist(at url: URL) throws {
        let plist: [String: Any] = [
            "Label": MicKeyManager.launchAgentLabel,
            "RunAtLoad": true,
            "ProgramArguments": [
                MicKeyManager.hidutilPath,
                "property",
                "--set",
                MicKeyManager.remapJSON,
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    @Test("Absent when plist file is missing")
    func absentWhenPlistMissing() throws {
        try TestSupport.withTemporaryDirectory { home in
            let manager = MicKeyManager(
                runProcess: { _, _ in
                    MicKeyProcessResult(terminationStatus: 0, stdout: "", stderr: "")
                },
                homeDirectory: { home },
                currentUID: { 501 }
            )
            #expect(manager.launchAgentStatus() == .absent)
        }
    }

    @Test("Valid loaded when plist is correct and launchctl print succeeds")
    func validLoadedWhenPrintSucceeds() throws {
        try TestSupport.withTemporaryDirectory { home in
            let plistURL = home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(MicKeyManager.launchAgentLabel).plist")
            try writeValidPlist(at: plistURL)

            let manager = MicKeyManager(
                runProcess: { path, args in
                    #expect(path == MicKeyManager.launchctlPath)
                    #expect(args == ["print", "gui/501/\(MicKeyManager.launchAgentLabel)"])
                    return MicKeyProcessResult(
                        terminationStatus: 0,
                        stdout: "state = not running\nruns = 1\n",
                        stderr: ""
                    )
                },
                homeDirectory: { home },
                currentUID: { 501 }
            )
            #expect(manager.launchAgentStatus() == .loaded)
        }
    }

    @Test("Valid but unloaded when launchctl print fails")
    func validButUnloadedWhenPrintFails() throws {
        try TestSupport.withTemporaryDirectory { home in
            let plistURL = home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(MicKeyManager.launchAgentLabel).plist")
            try writeValidPlist(at: plistURL)

            let manager = MicKeyManager(
                runProcess: { _, _ in
                    MicKeyProcessResult(terminationStatus: 113, stdout: "", stderr: "Could not find service")
                },
                homeDirectory: { home },
                currentUID: { 501 }
            )
            #expect(manager.launchAgentStatus() == .validButUnloaded)
        }
    }

    @Test("Invalid when Label is wrong")
    func invalidWhenLabelWrong() throws {
        try TestSupport.withTemporaryDirectory { home in
            let plistURL = home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(MicKeyManager.launchAgentLabel).plist")
            let plist: [String: Any] = [
                "Label": "com.example.other",
                "RunAtLoad": true,
                "ProgramArguments": [
                    MicKeyManager.hidutilPath,
                    "property",
                    "--set",
                    MicKeyManager.remapJSON,
                ],
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL)

            let manager = MicKeyManager(
                runProcess: { _, _ in
                    MicKeyProcessResult(terminationStatus: 0, stdout: "", stderr: "")
                },
                homeDirectory: { home },
                currentUID: { 501 }
            )
            guard case .invalid(let reason) = manager.launchAgentStatus() else {
                Issue.record("Expected invalid status")
                return
            }
            #expect(reason.contains("Label"))
        }
    }

    @Test("Invalid when ProgramArguments mapping differs")
    func invalidWhenArgumentsDiffer() throws {
        try TestSupport.withTemporaryDirectory { home in
            let plistURL = home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(MicKeyManager.launchAgentLabel).plist")
            let plist: [String: Any] = [
                "Label": MicKeyManager.launchAgentLabel,
                "RunAtLoad": true,
                "ProgramArguments": [
                    MicKeyManager.hidutilPath,
                    "property",
                    "--set",
                    #"{"UserKeyMapping":[]}"#,
                ],
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL)

            let manager = MicKeyManager(
                runProcess: { _, _ in
                    MicKeyProcessResult(terminationStatus: 0, stdout: "", stderr: "")
                },
                homeDirectory: { home },
                currentUID: { 501 }
            )
            guard case .invalid(let reason) = manager.launchAgentStatus() else {
                Issue.record("Expected invalid status")
                return
            }
            #expect(reason.contains("ProgramArguments"))
        }
    }

    @Test("validateLaunchAgentPlist accepts exact app-owned plist")
    func validateAcceptsExactPlist() throws {
        try TestSupport.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("agent.plist")
            try writeValidPlist(at: url)
            #expect(MicKeyManager.validateLaunchAgentPlist(at: url) == nil)
        }
    }
}
