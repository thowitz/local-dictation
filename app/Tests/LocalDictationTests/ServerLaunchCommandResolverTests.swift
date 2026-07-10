import Foundation
import Testing
@testable import LocalDictation

@Suite("ServerLaunchCommandResolver")
struct ServerLaunchCommandResolverTests {
    @Test("Override wins over lower candidates")
    func overrideWinsOverLowerCandidates() throws {
        try TestSupport.withTemporaryDirectory { root in
            let override = root.appendingPathComponent("override-bin")
            try TestSupport.writeFile(at: override, executable: true)

            let supportServe = root
                .appendingPathComponent("Support/server/bin/local-dictation-serve")
            try TestSupport.writeFile(at: supportServe, executable: true)

            let resolver = makeResolver(
                executableURL: root.appendingPathComponent("MacOS/LocalDictation"),
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: override.path).get()
            #expect(command.source == .override)
            #expect(command.executableURL.path == override.path)
            #expect(command.argumentPrefix == [])
        }
    }

    @Test("Invalid override fails without fallback")
    func invalidOverrideFailsWithoutFallback() throws {
        try TestSupport.withTemporaryDirectory { root in
            let missing = root.appendingPathComponent("missing-serve")
            let supportServe = root
                .appendingPathComponent("Support/server/bin/local-dictation-serve")
            try TestSupport.writeFile(at: supportServe, executable: true)

            let resolver = makeResolver(
                executableURL: root.appendingPathComponent("app"),
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let result = resolver.resolve(override: missing.path)
            guard case .failure(.overrideMissing(let path)) = result else {
                Issue.record("Expected overrideMissing, got \(result)")
                return
            }
            #expect(path == missing.path)

            let nonExec = root.appendingPathComponent("not-exec")
            try TestSupport.writeFile(at: nonExec, executable: false)
            let result2 = resolver.resolve(override: nonExec.path)
            guard case .failure(.overrideNotExecutable) = result2 else {
                Issue.record("Expected overrideNotExecutable, got \(result2)")
                return
            }
        }
    }

    @Test("Relative override fails authoritatively without fallback")
    func relativeOverrideFailsWithoutFallback() throws {
        try TestSupport.withTemporaryDirectory { root in
            let supportServe = root
                .appendingPathComponent("Support/server/bin/local-dictation-serve")
            try TestSupport.writeFile(at: supportServe, executable: true)
            try plantDevCheckout(at: root.appendingPathComponent("repo"))
            let exe = root.appendingPathComponent(
                "repo/.build/debug/LocalDictation"
            )
            try TestSupport.writeFile(at: exe, executable: true)

            let resolver = makeResolver(
                executableURL: exe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let result = resolver.resolve(override: "bin/serve")
            guard case .failure(.overrideNotAbsolute(let path)) = result else {
                Issue.record("Expected overrideNotAbsolute, got \(result)")
                return
            }
            #expect(path == "bin/serve")
            #expect(!failureDescription(result).isEmpty)
        }
    }

    @Test("Single repo-root marker is not enough for development")
    func singleRepoRootMarkerDoesNotSelectDevelopment() throws {
        try TestSupport.withTemporaryDirectory { root in
            // Only app/Package.swift — missing server/pyproject.toml.
            let packageOnly = root.appendingPathComponent("package-only")
            try TestSupport.writeFile(
                at: packageOnly.appendingPathComponent("app/Package.swift"),
                contents: "// swift-tools-version: 6.0\n",
                executable: false
            )
            try TestSupport.writeFile(
                at: packageOnly.appendingPathComponent("server/.venv/bin/local-dictation-serve"),
                executable: true
            )
            let exe1 = packageOnly.appendingPathComponent(".build/debug/LocalDictation")
            try TestSupport.writeFile(at: exe1, executable: true)

            let resolver1 = makeResolver(
                executableURL: exe1,
                home: root,
                support: root.appendingPathComponent("empty-support-a")
            )
            let result1 = resolver1.resolve(override: nil)
            if case .success(let command) = result1 {
                #expect(command.source != .development)
            } else if case .failure(.noCandidateFound) = result1 {
                // Expected when no other candidates exist.
            } else {
                Issue.record("Unexpected result for package-only markers: \(result1)")
            }

            // Only server/pyproject.toml — missing app/Package.swift.
            let pyprojectOnly = root.appendingPathComponent("pyproject-only")
            try TestSupport.writeFile(
                at: pyprojectOnly.appendingPathComponent("server/pyproject.toml"),
                contents: "[project]\nname = \"local-dictation-server\"\n",
                executable: false
            )
            try TestSupport.writeFile(
                at: pyprojectOnly.appendingPathComponent("server/.venv/bin/local-dictation-serve"),
                executable: true
            )
            let exe2 = pyprojectOnly.appendingPathComponent(".build/debug/LocalDictation")
            try TestSupport.writeFile(at: exe2, executable: true)

            let resolver2 = makeResolver(
                executableURL: exe2,
                home: root,
                support: root.appendingPathComponent("empty-support-b")
            )
            let result2 = resolver2.resolve(override: nil)
            if case .success(let command) = result2 {
                #expect(command.source != .development)
            } else if case .failure(.noCandidateFound) = result2 {
                // Expected.
            } else {
                Issue.record("Unexpected result for pyproject-only markers: \(result2)")
            }
        }
    }

    @Test("Repo markers beyond maxAncestorDepth are not found")
    func repoMarkersBeyondMaxAncestorDepthAreNotFound() throws {
        try TestSupport.withTemporaryDirectory { root in
            let repo = root.appendingPathComponent("deep-repo")
            try plantDevCheckout(at: repo)
            // Place the executable many levels below the repo root.
            let exe = repo.appendingPathComponent(
                "a/b/c/d/e/.build/debug/LocalDictation"
            )
            try TestSupport.writeFile(at: exe, executable: true)

            let resolver = makeResolver(
                executableURL: exe,
                home: root,
                support: root.appendingPathComponent("empty-support"),
                maxAncestorDepth: 3
            )
            let result = resolver.resolve(override: nil)
            if case .success(let command) = result {
                #expect(command.source != .development)
            } else if case .failure(.noCandidateFound) = result {
                // Expected — walk stops before reaching both markers.
            } else {
                Issue.record("Unexpected result for shallow ancestor walk: \(result)")
            }
        }
    }

    @Test("Bundle helper exact executable and prefix beats lower candidates")
    func bundleHelperExactExecutableAndPrefixBeatsLowerCandidates() throws {
        try TestSupport.withTemporaryDirectory { root in
            let appRoot = root.appendingPathComponent("LocalDictation.app")
            let macosExe = appRoot.appendingPathComponent("Contents/MacOS/LocalDictation")
            try TestSupport.writeFile(at: macosExe, executable: true)

            let helper = appRoot.appendingPathComponent(
                "Contents/Helpers/LocalDictationServer/bin/python3"
            )
            try TestSupport.writeFile(at: helper, executable: true)

            let supportServe = root
                .appendingPathComponent("Support/server/bin/local-dictation-serve")
            try TestSupport.writeFile(at: supportServe, executable: true)
            try plantDevCheckout(at: root.appendingPathComponent("repo"))

            let resolver = makeResolver(
                executableURL: macosExe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .bundleHelper)
            #expect(command.executableURL.path == helper.path)
            #expect(
                command.argumentPrefix
                    == ["-I", "-B", "-u", "-m", "local_dictation_server.server"]
            )
        }
    }

    @Test("No candidate under Contents/Resources/server")
    func noCandidateUnderContentsResourcesServer() throws {
        try TestSupport.withTemporaryDirectory { root in
            let appRoot = root.appendingPathComponent("LocalDictation.app")
            let macosExe = appRoot.appendingPathComponent("Contents/MacOS/LocalDictation")
            try TestSupport.writeFile(at: macosExe, executable: true)

            let resourcesServe = appRoot.appendingPathComponent(
                "Contents/Resources/server/bin/local-dictation-serve"
            )
            try TestSupport.writeFile(at: resourcesServe, executable: true)

            let helper = appRoot.appendingPathComponent(
                "Contents/Helpers/LocalDictationServer/bin/python3"
            )
            try TestSupport.writeFile(at: helper, executable: true)

            let resolver = makeResolver(
                executableURL: macosExe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .bundleHelper)
            #expect(!command.executableURL.path.contains("Contents/Resources/server"))

            try FileManager.default.removeItem(at: helper)
            let failure = resolver.resolve(override: nil)
            if case .failure(.noCandidateFound(let attempted)) = failure {
                for candidate in attempted {
                    #expect(
                        !candidate.url.path.contains("Contents/Resources/server"),
                        "Attempted candidate must not include Resources/server: \(candidate.url.path)"
                    )
                }
            }
        }
    }

    @Test("Bundle path containing spaces resolves helper")
    func bundlePathContainingSpacesResolvesHelper() throws {
        try TestSupport.withTemporaryDirectory { root in
            let appRoot = root.appendingPathComponent("My Apps/Local Dictation.app")
            let macosExe = appRoot.appendingPathComponent("Contents/MacOS/LocalDictation")
            try TestSupport.writeFile(at: macosExe, executable: true)

            let helper = appRoot.appendingPathComponent(
                "Contents/Helpers/LocalDictationServer/bin/python3"
            )
            try TestSupport.writeFile(at: helper, executable: true)

            let resolver = makeResolver(
                executableURL: macosExe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .bundleHelper)
            #expect(command.executableURL.path == helper.path)
            #expect(command.argumentPrefix == ServerLaunchCommand.bundleHelperArgumentPrefix)
        }
    }

    @Test("Packaged app refuses fall-through when helper is absent")
    func packagedAppRefusesFallThroughWhenHelperAbsent() throws {
        try TestSupport.withTemporaryDirectory { root in
            let appRoot = root.appendingPathComponent("LocalDictation.app")
            let macosExe = appRoot.appendingPathComponent("Contents/MacOS/LocalDictation")
            try TestSupport.writeFile(at: macosExe, executable: true)

            // Nearby checkout + Application Support would otherwise win.
            try plantDevCheckout(at: root.appendingPathComponent("repo"))
            let supportServe = root
                .appendingPathComponent("Support/server/bin/local-dictation-serve")
            try TestSupport.writeFile(at: supportServe, executable: true)

            let resolver = makeResolver(
                executableURL: macosExe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let result = resolver.resolve(override: nil)
            guard case .failure(.noCandidateFound(let attempted)) = result else {
                Issue.record("Expected packaged refusal, got \(result)")
                return
            }
            #expect(attempted.count == 1)
            #expect(attempted[0].source == .bundleHelper)
            #expect(attempted[0].status == .missing)
            #expect(
                attempted[0].url.path.hasSuffix(
                    "Contents/Helpers/LocalDictationServer/bin/python3"
                )
            )
        }
    }

    @Test("Successful relocation of a bundle still resolves helper")
    func successfulRelocationOfBundleResolvesHelper() throws {
        try TestSupport.withTemporaryDirectory { root in
            let original = root.appendingPathComponent("Original/LocalDictation.app")
            let macosExe = original.appendingPathComponent("Contents/MacOS/LocalDictation")
            try TestSupport.writeFile(at: macosExe, executable: true)
            let helper = original.appendingPathComponent(
                "Contents/Helpers/LocalDictationServer/bin/python3"
            )
            try TestSupport.writeFile(at: helper, executable: true)

            let relocated = root.appendingPathComponent("Moved Elsewhere/LocalDictation.app")
            try FileManager.default.createDirectory(
                at: relocated.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: original, to: relocated)

            let relocatedExe = relocated.appendingPathComponent("Contents/MacOS/LocalDictation")
            let relocatedHelper = relocated.appendingPathComponent(
                "Contents/Helpers/LocalDictationServer/bin/python3"
            )
            let resolver = makeResolver(
                executableURL: relocatedExe,
                home: root,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .bundleHelper)
            #expect(command.executableURL.path == relocatedHelper.path)
            #expect(command.argumentPrefix == ServerLaunchCommand.bundleHelperArgumentPrefix)
        }
    }

    @Test("Application Support order is deterministic")
    func applicationSupportOrderIsDeterministic() throws {
        try TestSupport.withTemporaryDirectory { root in
            let support = root.appendingPathComponent("Support")
            let primary = support.appendingPathComponent("server/bin/local-dictation-serve")
            let secondary = support.appendingPathComponent("server/.venv/bin/local-dictation-serve")
            try TestSupport.writeFile(at: primary, executable: true)
            try TestSupport.writeFile(at: secondary, executable: true)

            let resolver = makeResolver(
                executableURL: root.appendingPathComponent("not-an-app"),
                home: root,
                support: support
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .applicationSupport)
            #expect(command.executableURL.path == primary.path)

            try FileManager.default.removeItem(at: primary)
            let command2 = try resolver.resolve(override: nil).get()
            #expect(command2.executableURL.path == secondary.path)
        }
    }

    @Test("Development walk from triple .build layout")
    func developmentWalkFromTripleBuildLayout() throws {
        try TestSupport.withTemporaryDirectory { root in
            let repo = root.appendingPathComponent("my-clone")
            try plantDevCheckout(at: repo)
            let exe = repo.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/LocalDictation"
            )
            try TestSupport.writeFile(at: exe, executable: true)

            let resolver = makeResolver(
                executableURL: exe,
                home: root,
                support: root.appendingPathComponent("empty-support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .development)
            #expect(
                command.executableURL.path
                    == repo.appendingPathComponent("server/.venv/bin/local-dictation-serve").path
            )
            #expect(command.argumentPrefix == [])
        }
    }

    @Test("Development walk from shorthand .build layout")
    func developmentWalkFromShorthandBuildLayout() throws {
        try TestSupport.withTemporaryDirectory { root in
            let repo = root.appendingPathComponent("elsewhere/LocalDictation")
            try plantDevCheckout(at: repo)
            let exe = repo.appendingPathComponent(".build/release/LocalDictation")
            try TestSupport.writeFile(at: exe, executable: true)

            let resolver = makeResolver(
                executableURL: exe,
                home: root,
                support: root.appendingPathComponent("empty-support")
            )
            let command = try resolver.resolve(override: nil).get()
            #expect(command.source == .development)
            #expect(command.executableURL.path.hasSuffix("server/.venv/bin/local-dictation-serve"))
            #expect(command.executableURL.path.contains("elsewhere/LocalDictation"))
        }
    }

    @Test("No candidate lists every attempt without developer home")
    func noCandidateListsEveryAttemptWithoutDeveloperHome() throws {
        try TestSupport.withTemporaryDirectory { root in
            let exe = root.appendingPathComponent("orphan/bin/LocalDictation")
            try TestSupport.writeFile(at: exe, executable: true)
            let support = root.appendingPathComponent("Support")

            let resolver = makeResolver(executableURL: exe, home: root, support: support)
            let result = resolver.resolve(override: nil)
            guard case .failure(.noCandidateFound(let attempted)) = result else {
                Issue.record("Expected noCandidateFound, got \(result)")
                return
            }
            #expect(!attempted.isEmpty)
            #expect(attempted.contains { $0.source == .applicationSupport })
            for candidate in attempted {
                #expect(!candidate.url.path.contains("/Users/oxxxx"))
                #expect(!candidate.url.path.contains("compiledInRepoRoot"))
            }
            #expect(!failureDescription(result).contains("/Users/oxxxx"))
        }
    }

    @Test("Tilde expansion uses injected home")
    func tildeExpansionUsesInjectedHome() throws {
        try TestSupport.withTemporaryDirectory { root in
            let home = root.appendingPathComponent("fake-home")
            let serve = home.appendingPathComponent("tools/my-serve")
            try TestSupport.writeFile(at: serve, executable: true)

            let resolver = makeResolver(
                executableURL: root.appendingPathComponent("app"),
                home: home,
                support: root.appendingPathComponent("Support")
            )
            let command = try resolver.resolve(override: "~/tools/my-serve").get()
            #expect(command.source == .override)
            #expect(command.executableURL.path == serve.path)
        }
    }

    @Test("Supervisor argument assembly puts prefix before server args")
    func supervisorArgumentAssemblyPutsPrefixBeforeServerArgs() {
        let prefix = ServerLaunchCommand.bundleHelperArgumentPrefix
        let args = ServerLaunchCommand.processArguments(
            prefix: prefix,
            port: 8471,
            parentPID: 12345,
            model: "mlx-community/foo"
        )
        #expect(
            args == [
                "-I", "-B", "-u", "-m", "local_dictation_server.server",
                "--port", "8471",
                "--parent-pid", "12345",
                "--model", "mlx-community/foo",
            ]
        )

        let noModel = ServerLaunchCommand.processArguments(
            prefix: [],
            port: 9000,
            parentPID: 1,
            model: nil
        )
        #expect(noModel == ["--port", "9000", "--parent-pid", "1"])
    }

    @Test("Display and detail formatting")
    func displayAndDetailFormatting() {
        let command = ServerLaunchCommand(
            executableURL: URL(fileURLWithPath: "/opt/python3"),
            argumentPrefix: ServerLaunchCommand.bundleHelperArgumentPrefix,
            source: .bundleHelper
        )
        #expect(command.displayCommandLine.contains("/opt/python3"))
        #expect(command.displayCommandLine.contains("-m"))
        #expect(command.detailDescription.contains("bundleHelper"))
        #expect(command.detailDescription.contains("/opt/python3"))
    }

    // MARK: - Fixtures

    private func makeResolver(
        executableURL: URL,
        home: URL,
        support: URL,
        maxAncestorDepth: Int = 12
    ) -> ServerLaunchCommandResolver {
        ServerLaunchCommandResolver(
            executableURL: executableURL,
            homeDirectoryURL: home,
            supportDirectoryURL: support,
            fileExists: TestSupport.fileExists,
            isExecutable: TestSupport.isExecutable,
            maxAncestorDepth: maxAncestorDepth
        )
    }

    private func plantDevCheckout(at repo: URL) throws {
        try TestSupport.writeFile(
            at: repo.appendingPathComponent("app/Package.swift"),
            contents: "// swift-tools-version: 6.0\n",
            executable: false
        )
        try TestSupport.writeFile(
            at: repo.appendingPathComponent("server/pyproject.toml"),
            contents: "[project]\nname = \"local-dictation-server\"\n",
            executable: false
        )
        try TestSupport.writeFile(
            at: repo.appendingPathComponent("server/.venv/bin/local-dictation-serve"),
            executable: true
        )
    }

    private func failureDescription(
        _ result: Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError>
    ) -> String {
        switch result {
        case .success:
            return ""
        case .failure(let error):
            return error.description
        }
    }
}
