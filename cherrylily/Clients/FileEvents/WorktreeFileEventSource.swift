import Foundation

/// A live source of file-system change notifications for a directory tree.
/// `onBatch` receives a coalesced batch of changed absolute paths on an
/// arbitrary queue; consumers must hop to their own actor.
protocol WorktreeFileEventSource: AnyObject, Sendable {
  func stop()
}

/// Creates a started file-event source watching `paths` (recursively), coalescing
/// at `latency` seconds, delivering batches to `onBatch`.
typealias WorktreeFileEventSourceFactory = @Sendable (
  _ paths: [URL],
  _ latency: TimeInterval,
  _ onBatch: @escaping @Sendable ([String]) -> Void
) -> WorktreeFileEventSource
