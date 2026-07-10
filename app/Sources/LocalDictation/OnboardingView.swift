import AppKit
import SwiftUI

/// SwiftUI checklist hosted by `OnboardingWindowController`.
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    var onFinished: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Complete these steps so the 🎤 key reaches Local Dictation instead of macOS.")
                .foregroundStyle(.secondary)

            if let error = coordinator.snapshot.actionError {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let path = coordinator.snapshot.openFailurePath {
                Text("Open System Settings manually: \(path)")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(coordinator.snapshot.stepOrder.enumerated()), id: \.element) { index, step in
                        stepRow(index: index + 1, step: step)
                    }
                }
            }

            HStack {
                Button("Refresh") {
                    coordinator.refresh()
                }
                .disabled(coordinator.isBusy)

                Spacer()

                Button("Finish Later") {
                    onClose()
                }

                Button("Finish Setup") {
                    if coordinator.finishSetup() {
                        onFinished()
                    }
                }
                .disabled(!coordinator.snapshot.allRequiredComplete || coordinator.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
    }

    @ViewBuilder
    private func stepRow(index: Int, step: SetupStepID) -> some View {
        let complete = coordinator.snapshot.isComplete(step)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(complete ? .green : .secondary)
                Text("\(index). \(title(for: step))")
                    .font(.headline)
                Spacer()
                Text(coordinator.snapshot.statusText(for: step))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if step == .micKeyRemap {
                Toggle(
                    "Reapply at login (recommended)",
                    isOn: Binding(
                        get: { coordinator.snapshot.persistenceDesired },
                        set: { coordinator.setPersistenceDesired($0) }
                    )
                )
                .disabled(coordinator.isBusy)
            }

            if step == .dictationShortcut, coordinator.snapshot.dictationProbeDisagreesWithConfirmation {
                Text("Probe still reports the Dictation shortcut as on; your confirmation is accepted.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(actionTitle(for: step)) {
                    Task { await coordinator.performPrimaryAction(for: step) }
                }
                .disabled(coordinator.isBusy)

                if step == .inputMonitoring, !coordinator.snapshot.inputMonitoringConfirmed {
                    Button("I enabled/reviewed Input Monitoring") {
                        coordinator.confirmInputMonitoring()
                    }
                    .disabled(coordinator.isBusy)
                }

                if step == .dictationShortcut, !coordinator.snapshot.isComplete(.dictationShortcut) {
                    Button("I confirmed Shortcut is Off") {
                        coordinator.confirmDictationShortcutOff()
                    }
                    .disabled(coordinator.isBusy)
                }

                if step == .siriHoldF5, !coordinator.snapshot.isComplete(.siriHoldF5) {
                    Button("I confirmed press-and-hold is Off") {
                        coordinator.confirmSiriHoldF5Off()
                    }
                    .disabled(coordinator.isBusy)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func title(for step: SetupStepID) -> String {
        switch step {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .micKeyRemap: return "Mic-key remap"
        case .dictationShortcut: return "System Dictation shortcut"
        case .siriHoldF5: return "Siri press-and-hold F5"
        }
    }

    private func actionTitle(for step: SetupStepID) -> String {
        switch step {
        case .microphone:
            switch coordinator.snapshot.microphone {
            case .notRequested: return "Request Microphone Access"
            default: return "Open Microphone Settings"
            }
        case .accessibility: return "Open Accessibility Settings"
        case .inputMonitoring: return "Open Input Monitoring"
        case .micKeyRemap: return "Install/Test Remap"
        case .dictationShortcut: return "Open Dictation Settings"
        case .siriHoldF5: return "Open Siri Settings"
        }
    }
}

/// Retains one `NSWindow` and refreshes before every show.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let coordinator: OnboardingCoordinator
    private var window: NSWindow?
    private let makeWindow: (NSViewController) -> NSWindow
    private let presentWindow: (NSWindow) -> Void

    var isVisible: Bool {
        window?.isVisible == true
    }

    var onWillClose: (() -> Void)?

    init(
        coordinator: OnboardingCoordinator,
        makeWindow: @escaping (NSViewController) -> NSWindow = { content in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Local Dictation Setup"
            window.contentViewController = content
            window.center()
            window.isReleasedWhenClosed = false
            return window
        },
        presentWindow: @escaping (NSWindow) -> Void = { window in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.coordinator = coordinator
        self.makeWindow = makeWindow
        self.presentWindow = presentWindow
    }

    func show() {
        coordinator.refresh()
        if let window {
            presentWindow(window)
            return
        }

        let root = OnboardingView(
            coordinator: coordinator,
            onFinished: { [weak self] in
                self?.window?.close()
            },
            onClose: { [weak self] in
                self?.window?.close()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = makeWindow(hosting)
        window.delegate = self
        self.window = window
        presentWindow(window)
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
    }
}
