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
    }

    @Test("Explicit port and model decode")
    func explicitPortAndModelDecode() throws {
        let json = #"{"serverExecutable": "/opt/serve", "port": 9001, "model": "mlx-community/foo"}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.serverExecutable == "/opt/serve")
        #expect(config.port == 9001)
        #expect(config.model == "mlx-community/foo")
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
