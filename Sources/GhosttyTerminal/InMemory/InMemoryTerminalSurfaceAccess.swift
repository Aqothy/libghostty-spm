import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias RestoreSnapshot = @Sendable (ghostty_surface_t, Data) -> Bool
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let restoreSnapshot: RestoreSnapshot
    private let processExit: ProcessExit

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0

    init(
        write: @escaping Write,
        restoreSnapshot: @escaping RestoreSnapshot,
        processExit: @escaping ProcessExit
    ) {
        self.write = write
        self.restoreSnapshot = restoreSnapshot
        self.processExit = processExit
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        self.surface = nil
        waitForActiveOperations()
        self.surface = surface
        condition.unlock()
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations()
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    @discardableResult
    func enqueueWrite(_ data: Data) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                write(surface, data)
            }
        }
        return true
    }

    func restoreSnapshot(_ data: Data) async -> Bool? {
        guard let generation = currentGeneration else { return nil }

        return await withCheckedContinuation { continuation in
            outputQueue.async { [self] in
                let restored = withSurface(generation: generation) { surface in
                    restoreSnapshot(surface, data)
                }
                continuation.resume(returning: restored)
            }
        }
    }

    @discardableResult
    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
        return true
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    func waitForPendingOutput() {
        outputQueue.sync {}
    }

    private var currentGeneration: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return surface == nil ? nil : generation
    }

    private func withSurface<Result>(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func waitForActiveOperations() {
        while activeOperations > 0 {
            condition.wait()
        }
    }
}
