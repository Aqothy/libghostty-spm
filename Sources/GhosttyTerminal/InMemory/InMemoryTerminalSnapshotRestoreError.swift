import Foundation

/// A failure to install a complete GHOSTSNP terminal model.
public enum InMemoryTerminalSnapshotRestoreError: Error, Sendable {
    /// The session has no active Ghostty surface, or it was replaced before
    /// the queued restore could begin.
    case surfaceUnavailable

    /// Ghostty rejected an empty, malformed, incompatible, or wrong-sized
    /// snapshot without changing the current terminal model.
    case invalidSnapshot
}
