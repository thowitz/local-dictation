import Foundation
import Testing
@testable import LocalDictation

@Suite("RemapHealthAssessment")
struct RemapHealthAssessmentTests {
    @Test("No expectation yields noExpectation")
    func noExpectation() {
        let outcome = RemapHealthAssessment.evaluate(
            expectedActive: false,
            persistenceDesired: true,
            remapStatus: .missing,
            launchAgentStatus: .absent
        )
        #expect(outcome == .noExpectation)
    }

    @Test("Healthy when mapping installed and persistence satisfied")
    func healthy() {
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: true,
                remapStatus: .installed,
                launchAgentStatus: .loaded
            ) == .healthy
        )
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: false,
                remapStatus: .installed,
                launchAgentStatus: .absent
            ) == .healthy
        )
    }

    @Test("Session-only missing mapping is expectedMappingMissing")
    func sessionOnlyMissing() {
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: false,
                remapStatus: .missing,
                launchAgentStatus: .absent
            ) == .expectedMappingMissing
        )
    }

    @Test("Desired persistence absent/invalid/unloaded needs repair when mapping active")
    func persistenceNeedsRepair() {
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: true,
                remapStatus: .installed,
                launchAgentStatus: .absent
            ) == .activeButPersistenceNeedsRepair
        )
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: true,
                remapStatus: .installed,
                launchAgentStatus: .invalid("bad")
            ) == .activeButPersistenceNeedsRepair
        )
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: true,
                remapStatus: .installed,
                launchAgentStatus: .validButUnloaded
            ) == .activeButPersistenceNeedsRepair
        )
    }

    @Test("Probe failure is never reported as missing")
    func probeFailure() {
        #expect(
            RemapHealthAssessment.evaluate(
                expectedActive: true,
                persistenceDesired: true,
                remapStatus: .probeFailed("hidutil down"),
                launchAgentStatus: .loaded
            ) == .probeFailed("hidutil down")
        )
    }
}
