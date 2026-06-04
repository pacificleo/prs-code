import Darwin
import Dispatch
import Foundation

@MainActor
final class WorktreeInfoWatcherManager {
  private struct HeadWatcher {
    let headURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private struct RefreshTask {
    let interval: Duration
    let task: Task<Void, Never>
  }

  private struct PullRequestSelectionCooldownTask {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct RefreshTiming: Equatable {
    let focused: Duration
    let unfocused: Duration
  }

  private let filesChangedDebounceInterval: Duration
  private let pullRequestSelectionRefreshCooldown: Duration
  private let refreshTiming: RefreshTiming
  private let sleep: @Sendable (Duration) async throws -> Void
  private let fileEventSourceFactory: WorktreeFileEventSourceFactory
  private let gitCommonDirResolver: @Sendable (URL) async -> URL?
  private let discoveryInterval: Duration
  private let contentWatchLatency: TimeInterval
  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  private var branchDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var filesDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var restartTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var pullRequestTasks: [URL: RefreshTask] = [:]
  private var deferredLineChangeIDs: Set<Worktree.ID> = []
  private var hasCompletedInitialWorktreeLoad = false
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = true
  private var pullRequestSelectionCooldownTasksByRepo: [URL: PullRequestSelectionCooldownTask] = [:]
  private var eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation?
  private var contentSources: [Worktree.ID: WorktreeFileEventSource] = [:]
  private var ignoreMatchers: [Worktree.ID: GitIgnorePrefixMatcher] = [:]
  private var refsSources: [URL: WorktreeFileEventSource] = [:]
  private var refsCommonDirByRepository: [URL: URL] = [:]

  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    filesChangedDebounceInterval: Duration = .seconds(5),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    discoveryInterval: Duration = .seconds(150),
    contentWatchLatency: TimeInterval = 0.7,
    fileEventSourceFactory: @escaping WorktreeFileEventSourceFactory = liveWorktreeFileEventSourceFactory,
    gitCommonDirResolver: @escaping @Sendable (URL) async -> URL? = { await GitClient().gitCommonDir(for: $0) },
    clock: C = ContinuousClock()
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.filesChangedDebounceInterval = filesChangedDebounceInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.discoveryInterval = discoveryInterval
    self.contentWatchLatency = contentWatchLatency
    self.fileEventSourceFactory = fileEventSourceFactory
    self.gitCommonDirResolver = gitCommonDirResolver
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
  }

  func handleCommand(_ command: WorktreeInfoWatcherClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setSelectedWorktreeID(let worktreeID):
      setSelectedWorktreeID(worktreeID)
    case .setPullRequestTrackingEnabled(let isEnabled):
      setPullRequestTrackingEnabled(isEnabled)
    case .stop:
      stopAll()
    }
  }

  func eventStream() -> AsyncStream<WorktreeInfoWatcherClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeInfoWatcherClient.Event.self)
    eventContinuation = continuation
    return stream
  }

  private func setWorktrees(_ worktrees: [Worktree]) {
    let isInitialWorktreeLoad = !hasCompletedInitialWorktreeLoad && self.worktrees.isEmpty && !worktrees.isEmpty
    let worktreesByID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(self.worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
    }
    if !removedIDs.isEmpty {
      deferredLineChangeIDs.subtract(removedIDs)
    }
    let newIDs = desiredIDs.subtracting(currentIDs)
    if !newIDs.isEmpty && !isInitialWorktreeLoad {
      deferredLineChangeIDs.formUnion(newIDs)
    }
    self.worktrees = worktreesByID
    for worktree in worktrees {
      configureWatcher(for: worktree)
      updateLineChangeSchedule(
        worktreeID: worktree.id,
        immediate: isInitialWorktreeLoad || !deferredLineChangeIDs.contains(worktree.id)
      )
    }
    if isInitialWorktreeLoad {
      hasCompletedInitialWorktreeLoad = true
    }
    let repositoryRoots = Set(worktrees.map(\.repositoryRootURL))
    for repositoryRootURL in repositoryRoots {
      ensureRefsWatcher(repositoryRootURL: repositoryRootURL)
      updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
    }
    let obsoleteRepositories = pullRequestTasks.keys.filter { !repositoryRoots.contains($0) }
    for repositoryRootURL in obsoleteRepositories {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      refsSources.removeValue(forKey: repositoryRootURL)?.stop()
      refsCommonDirByRepository.removeValue(forKey: repositoryRootURL)
    }
    let obsoleteCooldownRepositories = pullRequestSelectionCooldownTasksByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteCooldownRepositories {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
  }

  private func setSelectedWorktreeID(_ worktreeID: Worktree.ID?) {
    guard selectedWorktreeID != worktreeID else {
      return
    }
    let previousWorktreeID = selectedWorktreeID
    let previousRepository = previousWorktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    selectedWorktreeID = worktreeID
    let nextRepository = worktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    if let previousWorktreeID {
      updateLineChangeSchedule(worktreeID: previousWorktreeID, immediate: false)
    }
    if let worktreeID {
      updateLineChangeSchedule(worktreeID: worktreeID, immediate: true)
    }
    if let previousRepository, previousRepository == nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: previousRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: previousRepository)
      )
      return
    }
    if let previousRepository {
      updatePullRequestSchedule(repositoryRootURL: previousRepository, immediate: false)
    }
    if let nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: nextRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: nextRepository)
      )
    }
  }

  private func configureWatcher(for worktree: Worktree) {
    guard
      let headURL = GitWorktreeHeadResolver.headURL(
        for: worktree.workingDirectory,
        fileManager: .default
      )
    else {
      stopWatcher(for: worktree.id)
      return
    }
    if let existing = headWatchers[worktree.id], existing.headURL == headURL {
      return
    }
    stopWatcher(for: worktree.id)
    startWatcher(worktreeID: worktree.id, headURL: headURL)
    startContentSource(for: worktree)
  }

  private func startWatcher(worktreeID: Worktree.ID, headURL: URL) {
    let path = headURL.path(percentEncoded: false)
    let fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      return
    }
    let queue = DispatchQueue(label: "worktree-info-watcher.\(worktreeID)")
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler { @Sendable [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleEvent(worktreeID: worktreeID, event: event)
      }
    }
    source.setCancelHandler { @Sendable in
      close(fileDescriptor)
    }
    source.resume()
    headWatchers[worktreeID] = HeadWatcher(headURL: headURL, source: source)
  }

  private func startContentSource(for worktree: Worktree) {
    let worktreeID = worktree.id
    let worktreeURL = worktree.workingDirectory
    contentSources[worktreeID]?.stop()
    if let gitDirectoryURL = GitWorktreeHeadResolver.headURL(for: worktreeURL, fileManager: .default)?
      .deletingLastPathComponent()
    {
      ignoreMatchers[worktreeID] = GitIgnorePrefixMatcher(
        worktreeURL: worktreeURL,
        gitDirectoryURL: gitDirectoryURL
      )
    }
    let source = fileEventSourceFactory([worktreeURL], contentWatchLatency) { [weak self] changedPaths in
      Task { @MainActor in
        self?.handleContentBatch(worktreeID: worktreeID, changedPaths: changedPaths)
      }
    }
    contentSources[worktreeID] = source
  }

  private func handleContentBatch(worktreeID: Worktree.ID, changedPaths: [String]) {
    guard let worktree = worktrees[worktreeID] else { return }
    let base = worktree.workingDirectory.path(percentEncoded: false)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    let matcher = ignoreMatchers[worktreeID]
    let hasRelevantChange = changedPaths.contains { path in
      guard path.hasPrefix(prefix) else { return false }
      let relative = String(path.dropFirst(prefix.count))
      if relative.isEmpty { return false }
      return matcher?.shouldIgnore(relativePath: relative) != true
    }
    guard hasRelevantChange else { return }
    scheduleFilesChanged(worktreeID: worktreeID)
  }

  private func handleEvent(
    worktreeID: Worktree.ID,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      stopHeadWatcher(for: worktreeID)
      scheduleRestart(worktreeID: worktreeID)
      scheduleBranchChanged(worktreeID: worktreeID)
      return
    }
    scheduleBranchChanged(worktreeID: worktreeID)
    scheduleFilesChanged(worktreeID: worktreeID)
  }

  private func scheduleBranchChanged(worktreeID: Worktree.ID) {
    branchDebounceTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.milliseconds(200))
      await MainActor.run {
        self?.emit(.branchChanged(worktreeID: worktreeID))
        if let repositoryRootURL = self?.worktrees[worktreeID]?.repositoryRootURL {
          self?.emitRefsChanged(repositoryRootURL: repositoryRootURL)
        }
      }
    }
    branchDebounceTasks[worktreeID] = task
  }

  private func scheduleFilesChanged(worktreeID: Worktree.ID) {
    filesDebounceTasks[worktreeID]?.cancel()
    let debounceInterval = filesChangedDebounceInterval
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(debounceInterval)
      await MainActor.run {
        guard let self else { return }
        self.emit(.filesChanged(worktreeID: worktreeID))
      }
    }
    filesDebounceTasks[worktreeID] = task
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.seconds(5))
      await MainActor.run {
        self?.restartWatcher(worktreeID: worktreeID)
      }
    }
    restartTasks[worktreeID] = task
  }

  private func restartWatcher(worktreeID: Worktree.ID) {
    guard headWatchers[worktreeID] == nil else {
      return
    }
    guard let worktree = worktrees[worktreeID] else {
      return
    }
    configureWatcher(for: worktree)
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  private func stopHeadWatcher(for worktreeID: Worktree.ID) {
    if let watcher = headWatchers.removeValue(forKey: worktreeID) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    branchDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    filesDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
    contentSources.removeValue(forKey: worktreeID)?.stop()
    ignoreMatchers.removeValue(forKey: worktreeID)
  }

  private func ensureRefsWatcher(repositoryRootURL: URL) {
    guard refsSources[repositoryRootURL] == nil else { return }
    let resolver = gitCommonDirResolver
    Task { [weak self] in
      guard let commonDir = await resolver(repositoryRootURL) else { return }
      await MainActor.run {
        self?.startRefsWatcher(repositoryRootURL: repositoryRootURL, commonDir: commonDir)
      }
    }
  }

  private func startRefsWatcher(repositoryRootURL: URL, commonDir: URL) {
    guard worktrees.values.contains(where: { $0.repositoryRootURL == repositoryRootURL }) else { return }
    guard refsSources[repositoryRootURL] == nil else { return }
    refsCommonDirByRepository[repositoryRootURL] = commonDir
    let watchPaths = [
      commonDir.appending(path: "refs"),
      commonDir.appending(path: "packed-refs"),
      commonDir.appending(path: "HEAD"),
    ]
    let source = fileEventSourceFactory(watchPaths, contentWatchLatency) { [weak self] _ in
      Task { @MainActor in
        self?.emitRefsChanged(repositoryRootURL: repositoryRootURL)
      }
    }
    refsSources[repositoryRootURL] = source
  }

  private func emitRefsChanged(repositoryRootURL: URL) {
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else { return }
    emit(.repositoryRefsChanged(repositoryRootURL: repositoryRootURL, worktreeIDs: worktreeIDs))
  }

  private func stopAll() {
    for watcher in headWatchers.values {
      watcher.source.cancel()
    }
    for task in branchDebounceTasks.values {
      task.cancel()
    }
    for task in filesDebounceTasks.values {
      task.cancel()
    }
    for task in restartTasks.values {
      task.cancel()
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    for source in contentSources.values {
      source.stop()
    }
    for source in refsSources.values { source.stop() }
    headWatchers.removeAll()
    branchDebounceTasks.removeAll()
    filesDebounceTasks.removeAll()
    restartTasks.removeAll()
    pullRequestTasks.removeAll()
    contentSources.removeAll()
    ignoreMatchers.removeAll()
    refsSources.removeAll()
    refsCommonDirByRepository.removeAll()
    deferredLineChangeIDs.removeAll()
    hasCompletedInitialWorktreeLoad = false
    cancelAllPullRequestSelectionCooldownTasks()
    worktrees.removeAll()
    selectedWorktreeID = nil
    pullRequestTrackingEnabled = true
    eventContinuation?.finish()
  }

  private func setPullRequestTrackingEnabled(_ enabled: Bool) {
    guard pullRequestTrackingEnabled != enabled else {
      return
    }
    pullRequestTrackingEnabled = enabled
    if enabled {
      let repositoryRoots = Set(worktrees.values.map(\.repositoryRootURL))
      for repositoryRootURL in repositoryRoots {
        updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
      }
      return
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    pullRequestTasks.removeAll()
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func updatePullRequestSchedule(repositoryRootURL: URL, immediate: Bool) {
    guard pullRequestTrackingEnabled else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let isFocused = selectedWorktreeID.map { worktreeIDs.contains($0) } ?? false
    if immediate {
      emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
    }
    // Only the focused repo runs a slow discovery poll (catches review/CI/web-created PRs
    // with no local ref signal). Background repos refresh on ref events + focus only.
    guard isFocused else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    if let existing = pullRequestTasks[repositoryRootURL], existing.interval == discoveryInterval, !immediate {
      return
    }
    pullRequestTasks[repositoryRootURL]?.task.cancel()
    let interval = discoveryInterval
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      while !Task.isCancelled {
        do { try await sleep(interval) } catch { break }
        guard !Task.isCancelled else { break }
        await MainActor.run { self?.emitPullRequestRefresh(repositoryRootURL: repositoryRootURL) }
      }
    }
    pullRequestTasks[repositoryRootURL] = RefreshTask(interval: interval, task: task)
  }

  private func repositoryWorktreeIDs(for repositoryRootURL: URL) -> [Worktree.ID] {
    worktrees
      .values
      .filter { $0.repositoryRootURL == repositoryRootURL }
      .map(\.id)
      .sorted()
  }

  private func emitPullRequestRefresh(repositoryRootURL: URL) {
    guard pullRequestTrackingEnabled else {
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      return
    }
    emit(.repositoryPullRequestRefresh(repositoryRootURL: repositoryRootURL, worktreeIDs: worktreeIDs))
  }

  private func updateLineChangeSchedule(
    worktreeID: Worktree.ID,
    immediate: Bool
  ) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    guard immediate else {
      return
    }
    deferredLineChangeIDs.remove(worktreeID)
    emit(.filesChanged(worktreeID: worktreeID))
  }

  private func emit(_ event: WorktreeInfoWatcherClient.Event) {
    if case .filesChanged(let worktreeID) = event,
      deferredLineChangeIDs.contains(worktreeID)
    {
      return
    }
    eventContinuation?.yield(event)
  }

  private func cancelPullRequestSelectionCooldown(for repositoryRootURL: URL) {
    pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)?.task.cancel()
  }

  private func cancelAllPullRequestSelectionCooldownTasks() {
    for task in pullRequestSelectionCooldownTasksByRepo.values {
      task.task.cancel()
    }
    pullRequestSelectionCooldownTasksByRepo.removeAll()
  }

  private func shouldImmediatelyRefreshPullRequests(repositoryRootURL: URL) -> Bool {
    guard pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] == nil else {
      return false
    }
    let cooldown = pullRequestSelectionRefreshCooldown
    let sleep = self.sleep
    let taskID = UUID()
    let task = Task { [weak self, sleep, taskID] in
      do {
        try await sleep(cooldown)
      } catch {
        return
      }
      await MainActor.run {
        guard
          let self,
          self.pullRequestSelectionCooldownTasksByRepo[repositoryRootURL]?.id == taskID
        else {
          return
        }
        self.pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)
      }
    }
    pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] = PullRequestSelectionCooldownTask(
      id: taskID,
      task: task
    )
    return true
  }
}
