import AppKit
import InputMethodKit
import LocalDictationIME

// Launched by macOS (not the user) while "Local Dictation" is the selected
// input source. The connection name and controller class come from Info.plist.
guard let server = IMKServer(
    name: InputMethodIdentity.connectionName,
    bundleIdentifier: Bundle.main.bundleIdentifier ?? InputMethodIdentity.bundleIdentifier
) else {
    fatalError("IMKServer failed to start")
}
_ = server
MainActor.assumeIsolated { InputMethodBridge.shared.start() }
log.info("Local Dictation input method started")
NSApplication.shared.run()
