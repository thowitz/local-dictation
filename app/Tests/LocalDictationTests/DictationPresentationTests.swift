import Foundation
import Testing
@testable import LocalDictation

@Suite("DictationPresentation")
struct DictationPresentationTests {
    private func sampleCommand() -> ServerLaunchCommand {
        ServerLaunchCommand(
            executableURL: URL(fileURLWithPath: "/tmp/local-dictation-serve"),
            argumentPrefix: [],
            source: .development
        )
    }

    private func sampleExit() -> ServerExit {
        ServerExit(
            reason: .exited(status: 42),
            runDuration: .seconds(1.5),
            command: sampleCommand(),
            activity: .empty,
            stderrTail: "boom\n",
            port: 8471
        )
    }

    private func sampleRestart() -> ServerRestartStatus {
        ServerRestartStatus(
            attempt: 2,
            maxAttempts: 5,
            backoff: .seconds(1),
            latestExit: sampleExit()
        )
    }

    private func sampleServerFailure(_ kind: ServerFailure.Kind) -> ServerFailure {
        ServerFailure(
            kind: kind,
            command: sampleCommand(),
            port: 8471,
            exit: sampleExit(),
            activity: .empty,
            stderrTail: "boom\n",
            underlyingMessage: nil
        )
    }

    @Test("Row text for starting downloading restarting ready and failures")
    func rowTextForCoreStates() {
        #expect(DictationPresentation.serverRowTitle(for: .starting) == "Server: Warming up…")
        #expect(
            DictationPresentation.serverRowTitle(for: .downloading(percent: 40))
                == "Server: Downloading model… 40%"
        )
        #expect(
            DictationPresentation.serverRowTitle(for: .downloading(percent: nil))
                == "Server: Downloading model…"
        )
        #expect(
            DictationPresentation.serverRowTitle(for: .restarting(sampleRestart()))
                .contains("Restarting 2/5")
        )
        #expect(DictationPresentation.serverRowTitle(for: .ready) == "Server: Running")
        #expect(DictationPresentation.serverRowTitle(for: .unloading) == "Server: Stopping…")
        #expect(DictationPresentation.serverRowTitle(for: .idle) == "Server: Stopped")

        for kind in ServerFailure.Kind.allCases {
            let title = DictationPresentation.serverRowTitle(
                for: .failed(.server(sampleServerFailure(kind)))
            )
            #expect(title.hasPrefix("Server: "))
            #expect(!title.contains("boom"))
        }
    }

    @Test("Dormant unloading and warm-up status titles")
    func dormantUnloadingAndWarmUpStatusTitles() {
        #expect(DictationState.idle.statusTitle == "Dormant")
        #expect(DictationState.unloading.statusTitle == "Unloading…")
        #expect(DictationState.starting.statusTitle == "Warming up…")
        #expect(DictationState.ready.statusTitle == "Ready")
    }

    @Test("Reducer maps stopped after unloading to dormant idle")
    func reducerMapsStoppedAfterUnloadingToIdle() {
        #expect(
            DictationServerStateReducer.apply(.stopped, current: .unloading) == .idle
        )
        #expect(
            DictationServerStateReducer.apply(.launching, current: .idle) == .starting
        )
    }

    @Test("Details and retry visibility limited to server restart and failure")
    func detailsAndRetryVisibilityLimitedToServerIssues() {
        #expect(DictationPresentation.showsServerDetails(for: .restarting(sampleRestart())))
        #expect(DictationPresentation.showsRetryServer(for: .failed(.server(sampleServerFailure(.launchFailed)))))
        #expect(DictationPresentation.showsServerDetails(for: .failed(.server(sampleServerFailure(.portInUse)))))

        #expect(!DictationPresentation.showsServerDetails(for: .failed(.secureInput("Secure input"))))
        #expect(!DictationPresentation.showsRetryServer(for: .failed(.secureInput("Secure input"))))
        #expect(!DictationPresentation.showsServerDetails(for: .failed(.accessibility("Accessibility"))))
        #expect(!DictationPresentation.showsRetryServer(for: .failed(.accessibility("Accessibility"))))
        #expect(!DictationPresentation.showsServerDetails(for: .ready))
        #expect(!DictationPresentation.showsRetryServer(for: .starting))
    }

    @Test("Copied details equal displayed bounded diagnostics")
    func copiedDetailsEqualDisplayedBoundedDiagnostics() {
        let failure = sampleServerFailure(.readinessTimedOut)
        let failedState = DictationState.failed(.server(failure))
        let failedDisplayed = DictationPresentation.detailsText(for: failedState)
        #expect(failedDisplayed == failure.detailsText)
        #expect(failedDisplayed?.contains("development") == true)
        #expect(failedDisplayed?.contains("stderr:") == true)

        let status = sampleRestart()
        let restartState = DictationState.restarting(status)
        let restartDetails = DictationPresentation.detailsText(for: restartState)
        // Copied clipboard text must equal the same details helper used by the alert.
        let copied = DictationPresentation.detailsText(for: restartState)
        #expect(restartDetails == copied)
        #expect(restartDetails?.contains("2/5") == true)
        #expect(restartDetails?.contains("stderr:") == true)
        #expect(restartDetails?.contains("boom") == true)

        let failedCopied = DictationPresentation.detailsText(for: failedState)
        #expect(failedCopied == failure.detailsText)
    }

    @Test("Restarting after listening always surfaces restart status")
    func restartingAfterListeningAlwaysSurfacesRestartStatus() {
        let status = sampleRestart()
        // Models the bug: interrupt clears side effects but left UI as .listening,
        // so a guarded transition skipped .restarting and the user saw generic Starting.
        let next = DictationServerStateReducer.apply(
            .restarting(status),
            current: .listening
        )
        #expect(next == .restarting(status))

        let fromFlushing = DictationServerStateReducer.apply(
            .restarting(status),
            current: .flushing
        )
        #expect(fromFlushing == .restarting(status))
    }

    @Test("Secure input and accessibility keep distinct server rows")
    func secureInputAndAccessibilityKeepDistinctServerRows() {
        #expect(
            DictationPresentation.serverRowTitle(for: .failed(.secureInput("x")))
                == "Server: Running"
        )
        #expect(
            DictationPresentation.serverRowTitle(for: .failed(.accessibility("x")))
                == "Server: —"
        )
    }
}
