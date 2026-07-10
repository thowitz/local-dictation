import AppKit
import Foundation

// MARK: - Public API
//
// IndicatorSounds plays start/stop pops resembling macOS dictation feedback.
//
// Integration (later pass):
//   IndicatorSounds.shared.enabled = userPreference  // menu toggle
//   IndicatorSounds.shared.playStart()               // on listen begin
//   IndicatorSounds.shared.playStop()                // on listen end / hide
//
// Prefers Apple's dictation recognition chime when present; otherwise falls
// back to /System/Library/Sounds (Tink / Pop) and finally NSSound(named:).

/// NSSound-based start/stop feedback for dictation toggle.
@MainActor
final class IndicatorSounds {
    static let shared = IndicatorSounds()

    /// When `false`, `playStart()` / `playStop()` are no-ops. App toggles this
    /// from the status-item menu ("Play dictation sounds").
    var enabled: Bool = true

    private let startSound: NSSound?
    private let stopSound: NSSound?

    private static let recognitionSoundPath =
        "/System/Library/PrivateFrameworks/SpeechObjects.framework/Versions/A/Frameworks/DictationServices.framework/Versions/A/Resources/DefaultRecognitionSound.aiff"
    private static let systemTinkPath = "/System/Library/Sounds/Tink.aiff"
    private static let systemPopPath = "/System/Library/Sounds/Pop.aiff"

    init() {
        startSound = Self.loadSound(
            preferredPaths: [Self.recognitionSoundPath, Self.systemTinkPath],
            namedFallback: "Tink"
        )
        stopSound = Self.loadSound(
            preferredPaths: [Self.systemPopPath, Self.recognitionSoundPath],
            namedFallback: "Pop"
        )
    }

    /// Soft chime when dictation listening begins.
    func playStart() {
        guard enabled else { return }
        startSound?.stop()
        startSound?.currentTime = 0
        startSound?.play()
    }

    /// Soft pop when dictation listening ends.
    func playStop() {
        guard enabled else { return }
        stopSound?.stop()
        stopSound?.currentTime = 0
        stopSound?.play()
    }

    private static func loadSound(preferredPaths: [String], namedFallback: String) -> NSSound? {
        for path in preferredPaths {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return NSSound(named: NSSound.Name(namedFallback))
    }
}
