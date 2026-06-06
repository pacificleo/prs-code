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
    // Pass `self` as the callback context with matching retain/release callbacks so
    // Core Services keeps this object alive for the entire lifetime of the stream.
    // Without this (passUnretained + nil retain/release), the stream can outlive the
    // source — if the owner drops/replaces it before calling stop(), the async
    // callback dereferences freed memory (EXC_BAD_ACCESS in objc_msgSend on a reused
    // allocation). The retain is balanced by FSEventStreamRelease in stop().
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: { rawInfo in
        guard let rawInfo else { return rawInfo }
        _ = Unmanaged<FSEventStreamFileEventSource>.fromOpaque(rawInfo).retain()
        return rawInfo
      },
      release: { rawInfo in
        guard let rawInfo else { return }
        Unmanaged<FSEventStreamFileEventSource>.fromOpaque(rawInfo).release()
      },
      copyDescription: nil
    )
    // kFSEventStreamCreateFlagUseCFTypes is REQUIRED: without it the callback's
    // `eventPaths` is a raw C `char **`, and bit-casting that to NSArray makes the
    // bridge send ObjC messages to path-string bytes (EXC_BAD_ACCESS). With this
    // flag `eventPaths` is a CFArray<CFString>, which bridges to [String] safely.
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagFileEvents
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
