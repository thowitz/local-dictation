import Foundation

/// One-shot main-actor idle deadline owned by `DictationController`.
///
/// Policy-free: the controller decides when to arm/reset/cancel and what to do
/// on fire. A stale sleeper from a prior generation never invokes its action.
@MainActor
final class IdleUnloadScheduler {
    private let timeout: Duration?
    private let sleep: (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// `nil` timeout disables arming (config `idleUnloadMinutes == 0`).
    init(
        timeout: Duration?,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.timeout = timeout
        self.sleep = sleep
    }

    var isArmed: Bool { task != nil }

    /// Arm a fresh full-interval deadline, cancelling any prior one.
    func reset(action: @escaping @MainActor () -> Void) {
        cancel()
        guard let timeout else { return }
        generation &+= 1
        let gen = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == gen {
                    self.task = nil
                }
            }
            do {
                try await self.sleep(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, self.generation == gen else { return }
            action()
        }
    }

    /// Arm only when not already armed (bootstrap path).
    func ensureArmed(action: @escaping @MainActor () -> Void) {
        guard !isArmed else { return }
        reset(action: action)
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
