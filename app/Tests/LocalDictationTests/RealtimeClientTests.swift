import Foundation
import Testing
@testable import LocalDictation

private final class StateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RealtimeClient.ConnectionState] = []

    func append(_ state: RealtimeClient.ConnectionState) {
        lock.lock()
        values.append(state)
        lock.unlock()
    }

    var snapshot: [RealtimeClient.ConnectionState] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { snapshot.count }
}

/// Non-MainActor controllable sleeper for RealtimeClient reconnect tests.
private final class ReconnectTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double = 0
    private var sleepers: [(id: UUID, deadline: Double, cont: CheckedContinuation<Void, Error>)] = []

    func sleep(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                let deadline = now + seconds
                if deadline <= now {
                    lock.unlock()
                    cont.resume()
                    return
                }
                sleepers.append((id, deadline, cont))
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            if let idx = self.sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = self.sleepers.remove(at: idx)
                self.lock.unlock()
                sleeper.cont.resume(throwing: CancellationError())
            } else {
                self.lock.unlock()
            }
        }
    }

    func advance(by duration: Duration) {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        lock.lock()
        now += seconds
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        lock.unlock()
        for sleeper in due {
            sleeper.cont.resume()
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("RealtimeClient")
struct RealtimeClientTests {
    @Test("Pre-disconnect scheduled reconnect does not reopen socket after disconnect")
    func staleReconnectDoesNotReopenAfterDisconnect() async {
        let clock = ReconnectTestClock()
        let client = RealtimeClient(
            endpoint: URL(string: "ws://127.0.0.1:9/v1/realtime")!,
            sleep: { try await clock.sleep($0) }
        )

        let probe = StateProbe()
        client.setCallbacks(
            RealtimeClient.Callbacks(
                onConnectionState: { probe.append($0) }
            )
        )

        // Prime auto-reconnect without opening a live peer socket.
        client.enableAutoReconnectForTesting()
        client.simulateUnexpectedDisconnectForTesting()
        #expect(probe.snapshot.last == .disconnected)

        let statesAfterDrop = probe.count
        let hookRan = Flag()

        client.reconnectRaceHook = {
            client.disconnect()
            hookRan.set()
        }

        // Let the reconnect Task register its sleeper before advancing.
        for _ in 0..<20 { await Task.yield() }

        clock.advance(by: .milliseconds(600))

        for _ in 0..<200 {
            if hookRan.isSet { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(hookRan.isSet)

        // Allow any post-hook openSocket work to publish.
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<20 { await Task.yield() }

        let after = Array(probe.snapshot.dropFirst(statesAfterDrop))
        #expect(!after.contains(.connecting))
        #expect(!client.isConnected)
        #expect(!after.contains(.disconnected))
    }

    @Test("disconnect while already disconnected does not republish")
    func disconnectWhileAlreadyDisconnectedDoesNotRepublish() {
        let client = RealtimeClient(endpoint: URL(string: "ws://127.0.0.1:9/v1/realtime")!)
        let probe = StateProbe()
        client.setCallbacks(
            RealtimeClient.Callbacks(onConnectionState: { probe.append($0) })
        )
        client.disconnect()
        client.disconnect()
        #expect(probe.snapshot.filter { $0 == .disconnected }.isEmpty)
    }
}
