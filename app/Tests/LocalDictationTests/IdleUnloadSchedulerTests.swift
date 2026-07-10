import Foundation
import Testing
@testable import LocalDictation

@Suite("IdleUnloadScheduler")
@MainActor
struct IdleUnloadSchedulerTests {
    private func pump(_ clock: FakeClock, advance: Duration = .milliseconds(10), times: Int = 1) async {
        for _ in 0..<times {
            await Task.yield()
            clock.advance(by: advance)
            await Task.yield()
        }
    }

    @Test("Arm fires action after timeout")
    func armFiresActionAfterTimeout() async {
        let clock = FakeClock()
        var fired = 0
        let scheduler = IdleUnloadScheduler(timeout: .milliseconds(100)) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { fired += 1 }
        #expect(scheduler.isArmed)

        await pump(clock, advance: .milliseconds(40), times: 1)
        #expect(fired == 0)
        #expect(scheduler.isArmed)

        await pump(clock, advance: .milliseconds(70), times: 2)
        #expect(fired == 1)
        #expect(!scheduler.isArmed)
    }

    @Test("Reset replaces prior deadline with a full interval")
    func resetReplacesPriorDeadline() async {
        let clock = FakeClock()
        var fired = 0
        let scheduler = IdleUnloadScheduler(timeout: .milliseconds(100)) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { fired += 1 }
        await pump(clock, advance: .milliseconds(80), times: 1)

        scheduler.reset { fired += 1 }
        await pump(clock, advance: .milliseconds(80), times: 1)
        #expect(fired == 0)

        await pump(clock, advance: .milliseconds(30), times: 2)
        #expect(fired == 1)
    }

    @Test("Cancel prevents fire")
    func cancelPreventsFire() async {
        let clock = FakeClock()
        var fired = 0
        let scheduler = IdleUnloadScheduler(timeout: .milliseconds(50)) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { fired += 1 }
        await Task.yield()
        scheduler.cancel()
        #expect(!scheduler.isArmed)

        await pump(clock, advance: .milliseconds(100), times: 2)
        #expect(fired == 0)
    }

    @Test("Stale generation after reset does not fire old action")
    func staleGenerationDoesNotFireOldAction() async {
        let clock = FakeClock()
        var firedOld = 0
        var firedNew = 0
        let scheduler = IdleUnloadScheduler(timeout: .milliseconds(100)) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { firedOld += 1 }
        await pump(clock, advance: .milliseconds(60), times: 1)

        scheduler.reset { firedNew += 1 }
        await pump(clock, advance: .milliseconds(110), times: 2)
        #expect(firedOld == 0)
        #expect(firedNew == 1)
    }

    @Test("Nil timeout never arms")
    func nilTimeoutNeverArms() async {
        let clock = FakeClock()
        var fired = 0
        let scheduler = IdleUnloadScheduler(timeout: nil) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { fired += 1 }
        scheduler.ensureArmed { fired += 1 }
        #expect(!scheduler.isArmed)

        await pump(clock, advance: .seconds(60), times: 1)
        #expect(fired == 0)
    }

    @Test("ensureArmed is a no-op when already armed")
    func ensureArmedIsNoOpWhenAlreadyArmed() async {
        let clock = FakeClock()
        var fired = 0
        let scheduler = IdleUnloadScheduler(timeout: .milliseconds(100)) { duration in
            try await clock.sleep(duration)
        }
        scheduler.reset { fired += 1 }
        await pump(clock, advance: .milliseconds(60), times: 1)

        scheduler.ensureArmed { fired += 10 }
        await pump(clock, advance: .milliseconds(50), times: 2)
        #expect(fired == 1)
    }
}
