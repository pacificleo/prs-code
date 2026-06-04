import CoreServices
import Foundation

/// `FSEventStream`-backed `WorktreeFileEventSource`. Coalesces at the OS level via
/// the stream `latency`, then hands the changed-path batch to `onBatch`.
nonisolated final class FSEventStreamFileEventSource: WorktreeFileEventSource, @unchecked Sendable {
  private let onBatch: @Sendable ([String]) -> Void
  private let queue: DispatchQueue
  private var stream: FSEventStreamRef?

  nonisolated init(paths: [URL], latency: TimeInterval, onBatch: @escaping @Sendable ([String]) -> Void) {
    self.onBatch = onBatch
    self.queue = DispatchQueue(label: "app.supabit.cherrylily.fsevents", qos: .utility)
    start(paths: paths, latency: latency)
  }

  private func start(paths: [URL], latency: TimeInterval) {
    guard !paths.isEmpty else { return }
    let cfPaths = paths.map { $0.path(percentEncoded: false) } as CFArray
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf
    )
    let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
      guard let info else { return }
      let source = Unmanaged<FSEventStreamFileEventSource>.fromOpaque(info).takeUnretainedValue()
      let rawPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
      if !rawPaths.isEmpty {
        source.onBatch(rawPaths)
      }
    }
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        callback,
        &context,
        cfPaths,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags
      )
    else {
      return
    }
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  nonisolated func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  nonisolated deinit {
    stop()
  }
}

/// Default live factory used by WorktreeInfoWatcherManager.
let liveWorktreeFileEventSourceFactory: WorktreeFileEventSourceFactory = { paths, latency, onBatch in
  FSEventStreamFileEventSource(paths: paths, latency: latency, onBatch: onBatch)
}
