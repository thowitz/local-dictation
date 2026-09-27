import Foundation
import Testing
@testable import LocalDictation

@Suite("InsertionMethod")
struct InsertionMethodTests {
    @Test("Default is live keystrokes, with the badge hidden for input-method modes")
    func defaults() throws {
        let config = try AppConfig.decode(Data("{}".utf8))
        #expect(config.insertionMethod == .keystrokes)
        #expect(config.hideInputSourceBadge)
    }

    @Test("Legacy useInputMethod=true maps to the input method while dictating")
    func legacyFlag() throws {
        #expect(try AppConfig.decode(Data(#"{"useInputMethod": false}"#.utf8)).insertionMethod == .keystrokes)
        #expect(try AppConfig.decode(Data(#"{"useInputMethod": true}"#.utf8)).insertionMethod == .switchPerDictation)
    }

    @Test("Explicit method wins over the legacy flag and round-trips")
    func roundTrip() throws {
        let json = #"{"insertionMethod": "always-selected", "useInputMethod": false, "hideInputSourceBadge": false}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.insertionMethod == .alwaysSelected)
        #expect(!config.hideInputSourceBadge)
        let again = try AppConfig.decode(JSONEncoder().encode(config))
        #expect(again.insertionMethod == .alwaysSelected)
        #expect(!again.hideInputSourceBadge)
    }

    @Test("Unknown method string falls back to the default")
    func unknownMethod() throws {
        #expect(try AppConfig.decode(Data(#"{"insertionMethod": "telepathy"}"#.utf8)).insertionMethod == .default)
    }

    @Test("Only keystrokes skips the input method; an old palette setting falls back")
    func methods() throws {
        #expect(!InsertionMethod.keystrokes.usesInputMethod)
        #expect(InsertionMethod.switchPerDictation.usesInputMethod)
        #expect(InsertionMethod.alwaysSelected.usesInputMethod)
        #expect(try AppConfig.decode(Data(#"{"insertionMethod": "palette"}"#.utf8)).insertionMethod == .default)
    }

    @Test("Setup hint: not enabled means adding it in Input Sources")
    func setupHints() {
        #expect(InputMethodSetupHint(.enabled) == .done)
        #expect(InputMethodSetupHint(.enabledNow) == .done)
        #expect(InputMethodSetupHint(.needsUser) == .addInputSource)
        #expect(InputMethodSetupHint(.notInstalled) == .addInputSource)
    }
}
