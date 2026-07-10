import AppKit
import Foundation
import Testing
@testable import LocalDictation

@Suite("OnboardingWindowController")
@MainActor
struct OnboardingWindowControllerTests {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "LocalDictation.OnboardingWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("Repeated show reuses one window, refreshes, and raises via presenter seam")
    func repeatedShowReusesWindow() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var refreshCount = 0
        var createdWindows = 0
        var presentedWindows: [ObjectIdentifier] = []

        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        let deps = OnboardingDependencies(
            microphoneStatus: {
                refreshCount += 1
                return .authorized
            },
            requestMicrophoneAccess: { true },
            isAccessibilityTrusted: { true },
            promptAccessibility: {},
            openURL: { _ in true },
            evaluateShortcuts: {
                FirstRunCheckReport(
                    dictationShortcut: .disabled,
                    siriHoldF5: .disabled,
                    appleDictationAutoEnable: 0,
                    symbolicHotKey164Enabled: false
                )
            },
            remapStatus: { .installed },
            launchAgentStatus: { .loaded },
            installAndVerifyRemap: { .installed },
            installLaunchAgent: {},
            removeRemap: {},
            removeLaunchAgent: {}
        )
        let coordinator = OnboardingCoordinator(preferences: prefs, dependencies: deps)

        let controller = OnboardingWindowController(
            coordinator: coordinator,
            makeWindow: { content in
                createdWindows += 1
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Local Dictation Setup"
                window.contentViewController = content
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                return window
            },
            presentWindow: { window in
                presentedWindows.append(ObjectIdentifier(window))
            }
        )

        controller.show()
        #expect(createdWindows == 1)
        #expect(presentedWindows.count == 1)
        let firstID = presentedWindows[0]
        let firstRefresh = refreshCount

        controller.show()
        #expect(createdWindows == 1)
        #expect(refreshCount > firstRefresh)
        #expect(presentedWindows.count == 2)
        #expect(presentedWindows[1] == firstID)
    }
}
