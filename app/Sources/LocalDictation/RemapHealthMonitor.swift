import Foundation
import os

/// Pure assessment of expected mic-key remap health.
enum RemapHealthOutcome: Equatable, Sendable {
    case healthy
    case activeButPersistenceNeedsRepair
    case expectedMappingMissing
    case probeFailed(String)
    /// No expectation — do not prompt.
    case noExpectation
}

enum RemapHealthAssessment {
    static func evaluate(
        expectedActive: Bool,
        persistenceDesired: Bool,
        remapStatus: MicKeyRemapStatus,
        launchAgentStatus: LaunchAgentStatus
    ) -> RemapHealthOutcome {
        guard expectedActive else { return .noExpectation }

        switch remapStatus {
        case .probeFailed(let message):
            return .probeFailed(message)
        case .missing:
            return .expectedMappingMissing
        case .installed:
            if persistenceDesired {
                switch launchAgentStatus {
                case .loaded:
                    return .healthy
                case .absent, .invalid, .validButUnloaded:
                    return .activeButPersistenceNeedsRepair
                }
            }
            return .healthy
        }
    }
}

enum RemapHealthTrigger: Equatable, Sendable {
    case launch
    case wakeOrSessionActive
}

struct RemapHealthIssue: Equatable, Sendable {
    var outcome: RemapHealthOutcome
    var trigger: RemapHealthTrigger

    var prefersRepairCopy: Bool {
        if case .activeButPersistenceNeedsRepair = outcome { return true }
        return false
    }
}

@MainActor
final class RemapHealthMonitor {
    struct Policy: Equatable, Sendable {
        var launchInitialDelay: Duration
        var launchRetryDelay: Duration
        var launchMissingRetries: Int
        var wakeInitialDelay: Duration
        var wakeMissingRetries: Int
        var notNowCooldown: Duration

        static let production = Policy(
            launchInitialDelay: .seconds(2),
            launchRetryDelay: .milliseconds(500),
            launchMissingRetries: 2,
            wakeInitialDelay: .seconds(1),
            wakeMissingRetries: 1,
            notNowCooldown: .seconds(30)
        )
    }

    struct Dependencies {
        var sleep: (Duration) async throws -> Void
        var now: () -> Date
        var expectedActive: () -> Bool
        var persistenceDesired: () -> Bool
        var remapStatus: () -> MicKeyRemapStatus
        var launchAgentStatus: () -> LaunchAgentStatus
        var isMutationInProgress: () -> Bool
        var isSetupVisibleAndIncomplete: () -> Bool
    }

    private let policy: Policy
    private let deps: Dependencies
    private let log = Logger(subsystem: AppLog.subsystem, category: "RemapHealth")

    private var checkTask: Task<Void, Never>?
    private var promptPresented = false
    private var notNowUntil: Date?
    var onIssue: ((RemapHealthIssue) -> Void)?

    init(policy: Policy = .production, dependencies: Dependencies) {
        self.policy = policy
        self.deps = dependencies
    }

    func scheduleLaunchCheck() {
        schedule(trigger: .launch)
    }

    func scheduleWakeOrSessionCheck() {
        schedule(trigger: .wakeOrSessionActive)
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
    }

    func noteNotNow() {
        notNowUntil = deps.now().addingTimeInterval(Self.seconds(policy.notNowCooldown))
        promptPresented = false
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    func notePromptDismissed() {
        promptPresented = false
    }

    func assessNow() -> RemapHealthOutcome {
        RemapHealthAssessment.evaluate(
            expectedActive: deps.expectedActive(),
            persistenceDesired: deps.persistenceDesired(),
            remapStatus: deps.remapStatus(),
            launchAgentStatus: deps.launchAgentStatus()
        )
    }

    private func schedule(trigger: RemapHealthTrigger) {
        checkTask?.cancel()
        checkTask = Task { @MainActor [weak self] in
            await self?.runCheck(trigger: trigger)
        }
    }

    private func runCheck(trigger: RemapHealthTrigger) async {
        let initialDelay = trigger == .launch ? policy.launchInitialDelay : policy.wakeInitialDelay
        let retries = trigger == .launch ? policy.launchMissingRetries : policy.wakeMissingRetries

        do {
            try await deps.sleep(initialDelay)
        } catch {
            return
        }

        for attempt in 0...retries {
            if Task.isCancelled { return }
            if deps.isMutationInProgress() {
                log.info("Remap health check deferred — mutation in progress")
                return
            }
            // Re-read expectation before prompting/restoring.
            guard deps.expectedActive() else {
                log.info("Remap health check skipped — expectation cleared")
                return
            }

            let outcome = assessNow()
            switch outcome {
            case .healthy, .noExpectation:
                return
            case .probeFailed(let message):
                log.error("Remap probe failed (not treated as missing): \(message, privacy: .public)")
                return
            case .expectedMappingMissing:
                if attempt < retries {
                    log.info("Expected mapping missing; retry \(attempt + 1)/\(retries)")
                    do {
                        try await deps.sleep(policy.launchRetryDelay)
                    } catch {
                        return
                    }
                    continue
                }
                presentIfAllowed(RemapHealthIssue(outcome: outcome, trigger: trigger))
                return
            case .activeButPersistenceNeedsRepair:
                presentIfAllowed(RemapHealthIssue(outcome: outcome, trigger: trigger))
                return
            }
        }
    }

    private func presentIfAllowed(_ issue: RemapHealthIssue) {
        if deps.isSetupVisibleAndIncomplete() {
            log.info("Suppressing remap recovery prompt — setup visible/incomplete")
            return
        }
        if promptPresented {
            log.info("Suppressing remap recovery prompt — already presenting")
            return
        }
        if let notNowUntil, deps.now() < notNowUntil {
            log.info("Suppressing remap recovery prompt — Not Now cooldown")
            return
        }
        // Final expectation re-read.
        guard deps.expectedActive() else { return }
        promptPresented = true
        onIssue?(issue)
    }
}
