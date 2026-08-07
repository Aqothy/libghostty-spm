@testable import GhosttyTerminal
import Darwin
import Foundation
import GhosttyKit
import Testing

struct InMemoryTerminalSessionOutputQueueTests {
    @Test
    func `receive returns before surface write completes`() {
        let writeStarted = DispatchSemaphore(value: 0)
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let session = makeSession { _, _ in
            writeStarted.signal()
            allowWriteToFinish.wait()
        }
        session.setSurface(testSurface(1))

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            allowWriteToFinish.signal()
        }

        let start = ProcessInfo.processInfo.systemUptime
        session.receive(Data("hello".utf8))
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 0.2)
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)
        allowWriteToFinish.signal()
        session.waitForPendingOutput()
    }

    @Test
    func `writes and process exit preserve enqueue order`() {
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            },
            processExit: { _, exitCode, runtimeMilliseconds in
                events.append("exit:\(exitCode):\(runtimeMilliseconds)")
            }
        )
        session.setSurface(testSurface(2))

        session.receive("first")
        session.receive("second")
        session.finish(exitCode: 7, runtimeMilliseconds: 42)
        session.waitForPendingOutput()

        #expect(events.values == ["first", "second", "exit:7:42"])
    }

    @Test
    func `snapshot restore is ordered with writes and awaits installation`() async throws {
        let restoreStarted = AsyncSignal()
        let allowRestoreToFinish = DispatchSemaphore(value: 0)
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            },
            surfaceRestoreSnapshot: { _, data in
                events.append("restore:\(String(decoding: data, as: UTF8.self))")
                restoreStarted.signal()
                allowRestoreToFinish.wait()
                return true
            }
        )
        session.setSurface(testSurface(3))

        session.receive("before")
        let restoreTask = Task {
            try await session.restore(snapshot: Data("snapshot".utf8))
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(1))
            restoreStarted.signal()
        }
        await restoreStarted.wait()
        timeoutTask.cancel()
        session.receive("after")

        #expect(events.values == ["before", "restore:snapshot"])
        allowRestoreToFinish.signal()
        try await restoreTask.value
        session.waitForPendingOutput()

        #expect(events.values == ["before", "restore:snapshot", "after"])
    }

    @Test
    func `restore reports a missing surface`() async {
        let session = makeSession { _, _ in }

        do {
            try await session.restore(snapshot: Data("snapshot".utf8))
            Issue.record("expected restore to fail without an active surface")
        } catch InMemoryTerminalSnapshotRestoreError.surfaceUnavailable {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func `surface teardown waits for active write and drops queued stale writes`() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWriteToFinish = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let writes = LockedValues<String>()
        let surface = SendableSurface(testSurface(4))
        let session = makeSession { _, data in
            let value = String(decoding: data, as: UTF8.self)
            writes.append(value)
            if value == "first" {
                firstWriteStarted.signal()
                allowFirstWriteToFinish.wait()
            }
        }
        session.setSurface(surface.rawValue)
        session.receive("first")
        session.receive("stale")
        #expect(firstWriteStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            session.clearSurface(ifMatches: surface.rawValue)
            clearFinished.signal()
        }

        let clearDeadline = ProcessInfo.processInfo.systemUptime + 1
        while session.currentSurface != nil,
              ProcessInfo.processInfo.systemUptime < clearDeadline
        {
            sched_yield()
        }
        #expect(session.currentSurface == nil)

        allowFirstWriteToFinish.signal()
        #expect(clearFinished.wait(timeout: .now() + 1) == .success)
        session.waitForPendingOutput()

        #expect(writes.values == ["first"])
    }

    @Test
    func `blocked session does not block another session`() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWriteToFinish = DispatchSemaphore(value: 0)
        let secondWriteFinished = DispatchSemaphore(value: 0)
        let firstSession = makeSession { _, _ in
            firstWriteStarted.signal()
            allowFirstWriteToFinish.wait()
        }
        let secondSession = makeSession { _, _ in
            secondWriteFinished.signal()
        }
        firstSession.setSurface(testSurface(5))
        secondSession.setSurface(testSurface(6))

        firstSession.receive("blocked")
        #expect(firstWriteStarted.wait(timeout: .now() + 1) == .success)
        secondSession.receive("independent")

        #expect(secondWriteFinished.wait(timeout: .now() + 1) == .success)
        allowFirstWriteToFinish.signal()
        firstSession.waitForPendingOutput()
        secondSession.waitForPendingOutput()
    }
}

private func makeSession(
    surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write
) -> InMemoryTerminalSession {
    InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in },
        surfaceWrite: surfaceWrite
    )
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private struct SendableSurface: @unchecked Sendable {
    let rawValue: ghostty_surface_t

    init(_ rawValue: ghostty_surface_t) {
        self.rawValue = rawValue
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard !isSignaled else {
            lock.unlock()
            return
        }
        isSignaled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
