import Foundation
import Testing
@testable import LocalDictation

@Suite("AppConfig")
struct AppConfigTests {
    @Test("Minimal JSON defaults port and model")
    func minimalJSONDefaultsPortAndModel() throws {
        let json = #"{"serverExecutable": "/tmp/custom-serve"}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.serverExecutable == "/tmp/custom-serve")
        #expect(config.port == AppConfig.defaultPort)
        #expect(config.model == nil)
        #expect(config.idleUnloadMinutes == AppConfig.defaultIdleUnloadMinutes)
        #expect(config.idleUnloadTimeout == .seconds(AppConfig.defaultIdleUnloadMinutes * 60))
    }

    @Test("Explicit port and model decode")
    func explicitPortAndModelDecode() throws {
        let json = #"{"serverExecutable": "/opt/serve", "port": 9001, "model": "mlx-community/foo"}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.serverExecutable == "/opt/serve")
        #expect(config.port == 9001)
        #expect(config.model == "mlx-community/foo")
        #expect(config.idleUnloadMinutes == AppConfig.defaultIdleUnloadMinutes)
    }

    @Test("Custom idleUnloadMinutes decodes")
    func customIdleUnloadMinutesDecodes() throws {
        let json = #"{"idleUnloadMinutes": 5}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.idleUnloadMinutes == 5)
        #expect(config.idleUnloadTimeout == .seconds(5 * 60))
    }

    @Test("Fractional idleUnloadMinutes is valid")
    func fractionalIdleUnloadMinutesIsValid() throws {
        let json = #"{"idleUnloadMinutes": 0.05}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.idleUnloadMinutes == 0.05)
        #expect(config.idleUnloadTimeout == .seconds(0.05 * 60))
    }

    @Test("Zero idleUnloadMinutes disables unload")
    func zeroIdleUnloadMinutesDisablesUnload() throws {
        let json = #"{"idleUnloadMinutes": 0}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.idleUnloadMinutes == 0)
        #expect(config.idleUnloadTimeout == nil)
    }

    @Test("Negative idleUnloadMinutes falls back to default")
    func negativeIdleUnloadMinutesFallsBackToDefault() throws {
        let json = #"{"idleUnloadMinutes": -3}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.idleUnloadMinutes == AppConfig.defaultIdleUnloadMinutes)
        #expect(config.idleUnloadTimeout == .seconds(AppConfig.defaultIdleUnloadMinutes * 60))
    }

    @Test("Idle unload decode preserves resolver fields")
    func idleUnloadDecodePreservesResolverFields() throws {
        let json = #"{"serverExecutable": "/opt/serve", "port": 9001, "model": "mlx-community/foo", "idleUnloadMinutes": 2.5}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.serverExecutable == "/opt/serve")
        #expect(config.port == 9001)
        #expect(config.model == "mlx-community/foo")
        #expect(config.idleUnloadMinutes == 2.5)
    }

    @Test("Invalid port is actionable")
    func invalidPortIsActionable() {
        do {
            _ = try AppConfig.decode(Data(#"{"port": 0}"#.utf8))
            Issue.record("Expected invalid port 0 to throw")
        } catch let error as AppConfig.ValidationError {
            #expect(error == .invalidPort(0))
            #expect(error.description.contains("1...65535"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try AppConfig.decode(Data(#"{"port": 70000}"#.utf8))
            Issue.record("Expected invalid port 70000 to throw")
        } catch let error as AppConfig.ValidationError {
            #expect(error == .invalidPort(70000))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Invalid port does not silently become default")
    func invalidPortDoesNotSilentlyBecomeDefault() {
        #expect(throws: AppConfig.ValidationError.self) {
            try AppConfig.decode(Data(#"{"port": -1}"#.utf8))
        }
        #expect(AppConfig().port == 8471)
    }

    @Test("Health and websocket URLs use port")
    func healthAndWebsocketURLsUsePort() {
        let config = AppConfig(port: 9001)
        #expect(config.healthURL.absoluteString == "http://127.0.0.1:9001/health")
        #expect(config.websocketURL.absoluteString == "ws://127.0.0.1:9001/v1/realtime")
    }

    @Test("Default provider is voxtral")
    func defaultProviderIsVoxtral() throws {
        let json = #"{}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.provider == .voxtral)
        #expect(config.parakeetModelPath == nil)
    }

    @Test("Parakeet provider and model path decode")
    func parakeetProviderAndModelPathDecode() throws {
        let json = #"{"provider": "parakeet", "parakeetModelPath": "~/parakeet-tdt-0.6b-v3-coreml"}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.provider == .parakeet)
        #expect(config.parakeetModelPath == "~/parakeet-tdt-0.6b-v3-coreml")
        #expect(config.parakeetChunkSeconds == AppConfig.defaultParakeetChunkSeconds)
        #expect(config.serverBackendFlag == nil)
    }

    @Test("Parakeet MLX provider resolves server flags")
    func parakeetMlxProviderResolvesServerFlags() throws {
        // Explicit HF id via `model` — no local path — so discovery cannot override.
        let json = #"{"provider": "parakeet-mlx", "model": "mlx-community/parakeet-tdt-0.6b-v3", "parakeetChunkSeconds": 0.75}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.provider == .parakeetMlx)
        #expect(config.serverBackendFlag == "parakeet-mlx")
        #expect(config.resolvedServerModel == "mlx-community/parakeet-tdt-0.6b-v3")
        #expect(config.parakeetChunkSeconds == 0.75)
        #expect(config.provider.usesPythonServer)
    }

    @Test("Parakeet MLX local path wins over HF model id")
    func parakeetMlxLocalPathWinsOverModelId() throws {
        let json = """
        {"provider": "parakeet-mlx", "model": "mlx-community/ignored", "parakeetMlxModelPath": "~/parakeet-tdt-0.6b-v3"}
        """
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.parakeetMlxModelPath == "~/parakeet-tdt-0.6b-v3")
        let resolved = config.resolvedServerModel ?? ""
        #expect(resolved.hasSuffix("/parakeet-tdt-0.6b-v3") || resolved.contains("parakeet-tdt-0.6b-v3"))
        #expect(!resolved.hasPrefix("mlx-community/"))
    }

    @Test("looksLikeParakeetMlxModelDirectory rejects CoreML trees")
    func looksLikeParakeetMlxRejectsCoreML() throws {
        try TestSupport.withTemporaryDirectory { root in
            // Fake CoreML-looking tree
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Encoder.mlmodelc"),
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
            #expect(!AppConfig.looksLikeParakeetMlxModelDirectory(root))

            // Fake MLX tree
            let mlx = root.appendingPathComponent("mlx", isDirectory: true)
            try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: mlx.appendingPathComponent("config.json"))
            try Data("x".utf8).write(to: mlx.appendingPathComponent("tokenizer.model"))
            #expect(AppConfig.looksLikeParakeetMlxModelDirectory(mlx))
        }
    }

    @Test("Provider is case-insensitive")
    func providerIsCaseInsensitive() throws {
        let json = #"{"provider": "Parakeet"}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.provider == .parakeet)
    }

    @Test("Invalid provider is actionable")
    func invalidProviderIsActionable() {
        do {
            _ = try AppConfig.decode(Data(#"{"provider": "whisper"}"#.utf8))
            Issue.record("Expected invalid provider to throw")
        } catch let error as AppConfig.ValidationError {
            #expect(error == .invalidProvider("whisper"))
            #expect(error.description.contains("voxtral"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("resolveServerLaunchCommand uses override")
    func resolveServerLaunchCommandUsesOverride() throws {
        try TestSupport.withTemporaryDirectory { root in
            let exe = root.appendingPathComponent("override-serve")
            try TestSupport.writeFile(at: exe, executable: true)
            let config = AppConfig(serverExecutable: exe.path, port: 8471)
            let result = config.resolveServerLaunchCommand(
                executableURL: root.appendingPathComponent("dummy"),
                homeDirectoryURL: root,
                supportDirectoryURL: root.appendingPathComponent("Support")
            )
            let command = try result.get()
            #expect(command.source == .override)
            #expect(command.executableURL.path == exe.path)
            #expect(command.argumentPrefix == [])
        }
    }
}
