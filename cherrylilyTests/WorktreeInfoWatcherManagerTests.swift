import Clocks
import Foundation
import Testing

@testable import CherryLily

@MainActor
struct WorktreeInfoWatcherManagerTests {
  @Test func emitsLineChangesImmediatelyOnInitialWorktreeLoad() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))

    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func defersLineChangesForWorktreesAddedAfterInitialLoad() async throws {
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func selectionRefreshUsesCooldownWithinRepository() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func filesChangedFiresOnNonIgnoredWorktreeEdit() async throws {
    let temp = try makeTempWorktree()
    let registry = FakeFileEventSourceRegistry()
    let factory: WorktreeFileEventSourceFactory = { paths, _, onBatch in
      let source = FakeFileEventSource(paths: paths, onBatch: onBatch)
      Task { await registry.add(source) }
      return source
    }
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .milliseconds(1),
      fileEventSourceFactory: factory
    )
    let (collector, task) = startCollecting(manager.eventStream())
    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([temp.worktree]))
    await drainAsyncEvents(120)
    let baseline = await collector.filesChangedCount(worktreeID: temp.worktree.id)

    let editedFile = temp.worktree.workingDirectory.appending(path: "Sources/App.swift").path(percentEncoded: false)
    await registry.source(watching: temp.worktree.workingDirectory)?.onBatch([editedFile])
    await drainAsyncEvents(120)

    #expect(await collector.filesChangedCount(worktreeID: temp.worktree.id) == baseline + 1)
    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: temp.tempRoot)
  }

  @Test func filesChangedSuppressedForGitInternalEdits() async throws {
    let temp = try makeTempWorktree()
    let registry = FakeFileEventSourceRegistry()
    let factory: WorktreeFileEventSourceFactory = { paths, _, onBatch in
      let source = FakeFileEventSource(paths: paths, onBatch: onBatch)
      Task { await registry.add(source) }
      return source
    }
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .milliseconds(1),
      fileEventSourceFactory: factory
    )
    let (collector, task) = startCollecting(manager.eventStream())
    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([temp.worktree]))
    await drainAsyncEvents(120)
    let baseline = await collector.filesChangedCount(worktreeID: temp.worktree.id)

    let gitFile = temp.worktree.workingDirectory.appending(path: ".git/index").path(percentEncoded: false)
    await registry.source(watching: temp.worktree.workingDirectory)?.onBatch([gitFile])
    await drainAsyncEvents(120)

    #expect(await collector.filesChangedCount(worktreeID: temp.worktree.id) == baseline)
    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: temp.tempRoot)
  }

  @Test func canceledSelectionCooldownDoesNotClearReplacementCooldown() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)

    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    let afterFirstSelectionCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterFirstSelectionCount == baselineCount + 1)

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setPullRequestTrackingEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    let afterReplacementCooldownCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterReplacementCooldownCount == afterFirstSelectionCount + 2)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(
      await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
        == afterReplacementCooldownCount
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func refsChangeEmitsRepositoryRefsChanged() async throws {
    let repo = try makeTempRepository(worktreeNames: ["sparrow"])
    let commonDir = repo.tempRoot.appending(path: ".git")
    let registry = FakeFileEventSourceRegistry()
    let factory: WorktreeFileEventSourceFactory = { paths, _, onBatch in
      let source = FakeFileEventSource(paths: paths, onBatch: onBatch)
      Task { await registry.add(source) }
      return source
    }
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      fileEventSourceFactory: factory,
      gitCommonDirResolver: { _ in commonDir }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    manager.handleCommand(.setWorktrees(repo.worktrees))
    await drainAsyncEvents(200)
    let baseline = await collector.repositoryRefsChangedCount(repositoryRootURL: repo.tempRoot)

    let refsDir = commonDir.appending(path: "refs")
    let pushed = refsDir.appending(path: "remotes/origin/sparrow").path(percentEncoded: false)
    await registry.source(watching: refsDir)?.onBatch([pushed])
    await drainAsyncEvents(200)

    #expect(await collector.repositoryRefsChangedCount(repositoryRootURL: repo.tempRoot) == baseline + 1)
    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: repo.tempRoot)
  }
}

final class FakeFileEventSource: WorktreeFileEventSource, @unchecked Sendable {
  let paths: [URL]
  let onBatch: @Sendable ([String]) -> Void
  private(set) var stopped = false
  init(paths: [URL], onBatch: @escaping @Sendable ([String]) -> Void) {
    self.paths = paths
    self.onBatch = onBatch
  }
  func stop() { stopped = true }
}

actor FakeFileEventSourceRegistry {
  private(set) var sources: [FakeFileEventSource] = []
  func add(_ source: FakeFileEventSource) { sources.append(source) }
  func source(watching url: URL) -> FakeFileEventSource? {
    sources.first { $0.paths.contains(url) }
  }
}

actor EventCollector {
  private var events: [WorktreeInfoWatcherClient.Event] = []

  func append(_ event: WorktreeInfoWatcherClient.Event) {
    events.append(event)
  }

  func filesChangedCount(worktreeID: Worktree.ID) -> Int {
    events.reduce(into: 0) { result, event in
      if case .filesChanged(let id) = event, id == worktreeID {
        result += 1
      }
    }
  }

  func pullRequestRefreshCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryPullRequestRefresh(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }

  func repositoryRefsChangedCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryRefsChanged(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }
}

private struct TempWorktree {
  let worktree: Worktree
  let tempRoot: URL
  let headURL: URL
}

private struct TempRepository {
  let worktrees: [Worktree]
  let tempRoot: URL
}

private func makeTempWorktree() throws -> TempWorktree {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  let worktreeDirectory = tempRoot.appending(path: "wt")
  let gitDirectory = worktreeDirectory.appending(path: ".git")
  try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
  let headURL = gitDirectory.appending(path: "HEAD")
  try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
  let worktree = Worktree(
    id: worktreeDirectory.path(percentEncoded: false),
    name: "eagle",
    detail: "detail",
    workingDirectory: worktreeDirectory,
    repositoryRootURL: tempRoot
  )
  return TempWorktree(worktree: worktree, tempRoot: tempRoot, headURL: headURL)
}

private func makeTempRepository(worktreeNames: [String]) throws -> TempRepository {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  var worktrees: [Worktree] = []
  for name in worktreeNames {
    let worktreeDirectory = tempRoot.appending(path: name)
    let gitDirectory = worktreeDirectory.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/\(name)\n".write(to: headURL, atomically: true, encoding: .utf8)
    let worktree = Worktree(
      id: worktreeDirectory.path(percentEncoded: false),
      name: name,
      detail: "detail",
      workingDirectory: worktreeDirectory,
      repositoryRootURL: tempRoot
    )
    worktrees.append(worktree)
  }
  return TempRepository(worktrees: worktrees, tempRoot: tempRoot)
}

private func startCollecting(
  _ stream: AsyncStream<WorktreeInfoWatcherClient.Event>
) -> (EventCollector, Task<Void, Never>) {
  let collector = EventCollector()
  let task = Task {
    for await event in stream {
      if Task.isCancelled {
        break
      }
      await collector.append(event)
    }
  }
  return (collector, task)
}

private func drainAsyncEvents(_ iterations: Int = 20) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}
