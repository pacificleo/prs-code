# Event-Driven Git Status & PR Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sidebar `+/-` pill, branch label, and PR status update from real file-system events instead of fixed-interval polling, and make each git call cheap, so idle laptop cost (CPU, SSD writes, battery/radio) drops to ~zero.

**Architecture:** Keep the git CLI. (1) Make `GitClient.lineChanges` cheap with `GIT_OPTIONAL_LOCKS=0` + a version-gated `-c core.fsmonitor=true`. (2) Add a reusable `FSEventStream`-backed file-event source; use it in `WorktreeInfoWatcherManager` to drive `.filesChanged` from real working-tree edits and to drive a per-repo refs watcher for push detection. (3) Remove the blind per-worktree line-change loop and per-repo PR loop; replace the PR loop with SHA-deduped ref-triggered refreshes plus one slow focused-repo-only discovery loop. (4) Switch the GitHub-availability recovery loop to exponential backoff.

**Tech Stack:** Swift 6.2, macOS 26+, The Composable Architecture (TCA), `swift-clocks` (`TestClock`), Swift Testing (`@Test`/`#expect`), CoreServices `FSEventStream`, `swift-dependencies`.

**Spec:** `docs/superpowers/specs/2026-06-03-event-driven-git-status-design.md`

**Phases (each independently shippable):**
- **Phase A** — Cheap git call (`GitClient` + capability cache). Tasks 1–3.
- **Phase B** — FSEvents content watcher replaces blind line-change polling. Tasks 4–8.
- **Phase C** — PR: ref-trigger + SHA dedupe + focused-only discovery. Tasks 9–13.
- **Phase D** — Exponential backoff for GitHub-availability recovery. Task 14.

**Conventions for every task:** 2-space indent, 120-col, trailing commas (SwiftLint strict). Use `SupaLogger`, never `print`. Build check: `make build-app`. Single-test run template (from `CLAUDE.md`):
```bash
xcodebuild test -project cherrylily.xcodeproj -scheme cherrylily -destination "platform=macOS" \
  -only-testing:cherrylilyTests/<TestType>/<testMethod> \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```
Commit only the files you touched (never `git add .`), per `CLAUDE.md`.

---

## Phase A — Cheap git call

### Task 1: `GitCapabilities` actor caching fsmonitor support

Detects once whether the active `git` supports built-in `core.fsmonitor` (git ≥ 2.37). Old git treats `core.fsmonitor=true` as a hook *path* and would error, so we must gate the flag.

**Files:**
- Create: `cherrylily/Clients/Git/GitCapabilities.swift`
- Test: `cherrylilyTests/GitCapabilitiesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import CherryLily

struct GitCapabilitiesTests {
  @Test func parsesModernVersionAsSupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.39.5 (Apple Git-154)") == true)
  }

  @Test func parsesExactThresholdAsSupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.37.0") == true)
  }

  @Test func parsesOldVersionAsUnsupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.36.9") == false)
  }

  @Test func parsesGarbageAsUnsupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "not a version") == false)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project cherrylily.xcodeproj -scheme cherrylily -destination "platform=macOS" -only-testing:cherrylilyTests/GitCapabilitiesTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation`
Expected: FAIL — `GitCapabilities` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Detects (once) whether the active `git` supports built-in `core.fsmonitor`
/// (git >= 2.37). Older git interprets `core.fsmonitor=true` as a hook path and
/// errors, so the flag must be gated on this check.
actor GitCapabilities {
  static let shared = GitCapabilities()

  private let shell: ShellClient
  private var cachedFsmonitorSupport: Bool?

  init(shell: ShellClient = .live) {
    self.shell = shell
  }

  func supportsFsmonitor() async -> Bool {
    if let cachedFsmonitorSupport {
      return cachedFsmonitorSupport
    }
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let output = try? await shell.run(env, ["git", "--version"], nil).stdout
    let supported = Self.parseFsmonitorSupport(fromVersionOutput: output ?? "")
    cachedFsmonitorSupport = supported
    return supported
  }

  /// Parses `git version X.Y.Z` and returns true when (X, Y) >= (2, 37).
  nonisolated static func parseFsmonitorSupport(fromVersionOutput output: String) -> Bool {
    guard let match = output.firstMatch(of: /git version (\d+)\.(\d+)/) else {
      return false
    }
    let major = Int(match.1) ?? 0
    let minor = Int(match.2) ?? 0
    return (major, minor) >= (2, 37)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Clients/Git/GitCapabilities.swift cherrylilyTests/GitCapabilitiesTests.swift
git commit -m "feat: add GitCapabilities fsmonitor detection"
```

---

### Task 2: `GitClient.lineChanges` runs cheaply

Add `GIT_OPTIONAL_LOCKS=0` (suppresses `.git/index` writeback) and a version-gated `-c core.fsmonitor=true` (skips the O(N) lstat scan on large repos).

**Files:**
- Modify: `cherrylily/Clients/Git/GitClient.swift` (`runGit` at `:636-647`, `lineChanges` at `:425-440`)
- Test: `cherrylilyTests/GitClientLineChangesTests.swift`

- [ ] **Step 1: Write the failing test**

A fake `ShellClient` records the executable + argv so we can assert the env var and flag are present. `GIT_OPTIONAL_LOCKS=0` is passed as an `env` argument (the call already runs `/usr/bin/env git …`).

```swift
import Foundation
import Testing

@testable import CherryLily

struct GitClientLineChangesTests {
  @Test func lineChangesPassesOptionalLocksAndFsmonitorWhenSupported() async throws {
    let recorded = LockIsolated<[String]>([])
    let shell = ShellClient(
      run: { _, arguments, _ in
        recorded.setValue(arguments)
        if arguments.contains("--version") {
          return ShellOutput(stdout: "git version 2.39.5", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: " 1 file changed, 3 insertions(+), 1 deletion(-)\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let capabilities = GitCapabilities(shell: shell)
    let client = GitClient(shell: shell, capabilities: capabilities)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/wt"))

    #expect(changes?.added == 3)
    #expect(changes?.removed == 1)
    let args = recorded.value
    #expect(args.contains("GIT_OPTIONAL_LOCKS=0"))
    #expect(args.contains("core.fsmonitor=true"))
  }

  @Test func lineChangesOmitsFsmonitorWhenUnsupported() async throws {
    let recorded = LockIsolated<[String]>([])
    let shell = ShellClient(
      run: { _, arguments, _ in
        recorded.setValue(arguments)
        if arguments.contains("--version") {
          return ShellOutput(stdout: "git version 2.30.0", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))

    _ = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/wt"))

    #expect(recorded.value.contains("GIT_OPTIONAL_LOCKS=0"))
    #expect(!recorded.value.contains("core.fsmonitor=true"))
  }
}
```

> Note: the fake records only the *last* call's argv; `lineChanges` runs `git diff` after `--version`, so `recorded.value` holds the diff argv. The `--version` call is issued by `GitCapabilities` through the same shell.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:cherrylilyTests/GitClientLineChangesTests …`
Expected: FAIL — `GitClient(shell:capabilities:)` initializer does not exist.

- [ ] **Step 3: Write minimal implementation**

In `GitClient.swift`, extend the stored deps + init (currently `:55-59`):

```swift
  private let shell: ShellClient
  private let capabilities: GitCapabilities

  nonisolated init(shell: ShellClient = .live, capabilities: GitCapabilities = .shared) {
    self.shell = shell
    self.capabilities = capabilities
  }
```

Replace `lineChanges(at:)` (`:425-440`) so it builds cheap-mode git args:

```swift
  nonisolated func lineChanges(at worktreeURL: URL) async -> (added: Int, removed: Int)? {
    if isWorktreeIndexLocked(worktreeURL) {
      return nil
    }
    let path = worktreeURL.path(percentEncoded: false)
    let fsmonitorArgs = await capabilities.supportsFsmonitor() ? ["-c", "core.fsmonitor=true"] : []
    do {
      let diff = try await runGit(
        operation: .lineChanges,
        gitArguments: fsmonitorArgs + ["-C", path, "diff", "HEAD", "--shortstat"],
        environment: ["GIT_OPTIONAL_LOCKS=0"]
      )
      let changes = parseShortstat(diff)
      return (added: changes.added, removed: changes.removed)
    } catch {
      return nil
    }
  }
```

Replace `runGit` (`:636-647`) to accept optional environment + pre-built git arguments while preserving the existing call shape. Add a new overload and keep the old signature delegating to it so other call sites are untouched:

```swift
  nonisolated private func runGit(
    operation: GitOperation,
    arguments: [String]
  ) async throws -> String {
    try await runGit(operation: operation, gitArguments: arguments, environment: [])
  }

  nonisolated private func runGit(
    operation: GitOperation,
    gitArguments: [String],
    environment: [String]
  ) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let argv = environment + ["git"] + gitArguments
    let command = ([env.path(percentEncoded: false)] + argv).joined(separator: " ")
    do {
      return try await shell.run(env, argv, nil).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (2 tests).

- [ ] **Step 5: Build**

Run: `make build-app`
Expected: build succeeds (confirms `GitClient(shell:capabilities:)` default still satisfies every existing `GitClient(shell:)` / `GitClient()` call site).

- [ ] **Step 6: Commit**

```bash
git add cherrylily/Clients/Git/GitClient.swift cherrylilyTests/GitClientLineChangesTests.swift
git commit -m "feat: run lineChanges with no index writeback and fsmonitor"
```

---

### Task 3: `GitClient.headSHA(for:)` for PR SHA dedupe

A cheap local SHA read used later (Phase C) to skip redundant `gh` calls.

**Files:**
- Modify: `cherrylily/Clients/Git/GitClient.swift` (add method near `lineChanges`); add `case headSHA = "head_sha"` to `GitOperation` (`:11-28`)
- Modify: `cherrylily/Clients/Repositories/GitClientDependency.swift` (add `headSHA` closure so the reducer can call it through the dependency wrapper)
- Test: `cherrylilyTests/GitClientHeadSHATests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import CherryLily

struct GitClientHeadSHATests {
  @Test func headSHAReturnsTrimmedRevParseOutput() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        #expect(arguments.contains("rev-parse"))
        #expect(arguments.contains("HEAD"))
        return ShellOutput(stdout: "abc123def456\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))

    let sha = await client.headSHA(for: URL(fileURLWithPath: "/tmp/wt"))

    #expect(sha == "abc123def456")
  }

  @Test func headSHAReturnsNilOnFailure() async throws {
    let shell = ShellClient(
      run: { _, _, _ in throw ShellClientError(command: "git", stdout: "", stderr: "boom", exitCode: 128) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))

    let sha = await client.headSHA(for: URL(fileURLWithPath: "/tmp/wt"))

    #expect(sha == nil)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:cherrylilyTests/GitClientHeadSHATests …`
Expected: FAIL — `headSHA(for:)` undefined.

- [ ] **Step 3: Write minimal implementation**

Add `case headSHA = "head_sha"` to the `GitOperation` enum, then add:

```swift
  nonisolated func headSHA(for worktreeURL: URL) async -> String? {
    let path = worktreeURL.path(percentEncoded: false)
    guard
      let output = try? await runGit(
        operation: .headSHA,
        arguments: ["-C", path, "rev-parse", "HEAD"]
      )
    else {
      return nil
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
```

- [ ] **Step 4: Expose `headSHA` on the dependency wrapper**

In `cherrylily/Clients/Repositories/GitClientDependency.swift`, add the closure property (after `lineChanges` at `:37`):

```swift
  var headSHA: @Sendable (URL) async -> String?
```

and wire it in `liveValue` (after the `lineChanges:` line at `:86`):

```swift
      headSHA: { await client.headSHA(for: $0) },
```

- [ ] **Step 5: Run test to verify it passes**

Run the Step 2 command, then `make build-app`. Expected: test PASS (2 tests); build succeeds (the new stored property is provided in the single `liveValue`/`testValue` initializer, so no other call site breaks).

- [ ] **Step 6: Commit**

```bash
git add cherrylily/Clients/Git/GitClient.swift cherrylily/Clients/Repositories/GitClientDependency.swift cherrylilyTests/GitClientHeadSHATests.swift
git commit -m "feat: add GitClient.headSHA for PR dedupe"
```

---

## Phase B — FSEvents content watcher

### Task 4: `GitIgnorePrefixMatcher` (top-level ignore prefilter)

Pure parser: top-level `.gitignore` + `.git/info/exclude` → set of ignored directory prefixes; matches relative paths. Used to drop noisy FSEvent paths before scheduling a git run.

**Files:**
- Create: `cherrylily/Support/GitIgnorePrefixMatcher.swift`
- Test: `cherrylilyTests/GitIgnorePrefixMatcherTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import CherryLily

struct GitIgnorePrefixMatcherTests {
  @Test func ignoresTopLevelDirectoryEntries() {
    let matcher = GitIgnorePrefixMatcher(lines: ["node_modules/", "build", "# comment", "", "  dist/  "])
    #expect(matcher.shouldIgnore(relativePath: "node_modules/react/index.js"))
    #expect(matcher.shouldIgnore(relativePath: "build/app.o"))
    #expect(matcher.shouldIgnore(relativePath: "dist/bundle.js"))
    #expect(!matcher.shouldIgnore(relativePath: "Sources/App.swift"))
  }

  @Test func alwaysIgnoresGitInternals() {
    let matcher = GitIgnorePrefixMatcher(lines: [])
    #expect(matcher.shouldIgnore(relativePath: ".git/HEAD"))
    #expect(matcher.shouldIgnore(relativePath: ".git/objects/ab/cd"))
  }

  @Test func skipsNegationsAndNestedPatternsConservatively() {
    // Negations and path-bearing patterns are not prefix-safe; ignore them (git remains source of truth).
    let matcher = GitIgnorePrefixMatcher(lines: ["!keep/", "src/generated/"])
    #expect(!matcher.shouldIgnore(relativePath: "keep/file"))
    #expect(!matcher.shouldIgnore(relativePath: "src/generated/x"))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:cherrylilyTests/GitIgnorePrefixMatcherTests …`
Expected: FAIL — type undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Cheap, conservative top-level `.gitignore` prefilter. Only handles simple
/// top-level directory/file entries (the 90% noise case: `node_modules/`,
/// `build/`, …). Negations and nested/path patterns are skipped on purpose —
/// `git diff` remains the source of truth, so a missed ignore only costs one
/// cheap git run, never correctness.
struct GitIgnorePrefixMatcher {
  private let prefixes: [String]

  init(lines: [String]) {
    var prefixes: [String] = []
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") {
        continue
      }
      // Skip patterns that carry a path separator in the middle, globs, or anchors.
      let body = line.hasSuffix("/") ? String(line.dropLast()) : line
      if body.contains("/") || body.contains("*") || body.hasPrefix("/") {
        continue
      }
      if !body.isEmpty {
        prefixes.append(body + "/")
      }
    }
    self.prefixes = prefixes
  }

  /// Loads top-level `.gitignore` and `.git/info/exclude` for a worktree.
  init(worktreeURL: URL, gitDirectoryURL: URL, fileManager: FileManager = .default) {
    var lines: [String] = []
    let gitignore = worktreeURL.appending(path: ".gitignore")
    let exclude = gitDirectoryURL.appending(path: "info/exclude")
    for url in [gitignore, exclude] {
      if let content = try? String(contentsOf: url, encoding: .utf8) {
        lines.append(contentsOf: content.split(whereSeparator: \.isNewline).map(String.init))
      }
    }
    self.init(lines: lines)
  }

  func shouldIgnore(relativePath: String) -> Bool {
    if relativePath == ".git" || relativePath.hasPrefix(".git/") {
      return true
    }
    return prefixes.contains { relativePath.hasPrefix($0) }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Support/GitIgnorePrefixMatcher.swift cherrylilyTests/GitIgnorePrefixMatcherTests.swift
git commit -m "feat: add GitIgnorePrefixMatcher noise prefilter"
```

---

### Task 5: `WorktreeFileEventSource` protocol + factory typealias

Defines the seam the manager depends on, so the FSEvents implementation and a test fake are interchangeable.

**Files:**
- Create: `cherrylily/Clients/FileEvents/WorktreeFileEventSource.swift`

- [ ] **Step 1: Write the protocol (no test — pure interface)**

```swift
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
```

- [ ] **Step 2: Build**

Run: `make build-app`
Expected: build succeeds (interface compiles; no consumers yet).

- [ ] **Step 3: Commit**

```bash
git add cherrylily/Clients/FileEvents/WorktreeFileEventSource.swift
git commit -m "feat: add WorktreeFileEventSource protocol"
```

---

### Task 6: `FSEventStreamFileEventSource` (live implementation)

Wraps the CoreServices `FSEventStream` C API. Not unit-tested directly (C run-loop callback); verified by build + the manager integration tests using the fake.

**Files:**
- Create: `cherrylily/Clients/FileEvents/FSEventStreamFileEventSource.swift`

- [ ] **Step 1: Write the implementation**

```swift
import CoreServices
import Foundation

/// `FSEventStream`-backed `WorktreeFileEventSource`. Coalesces at the OS level via
/// the stream `latency`, then hands the changed-path batch to `onBatch`.
final class FSEventStreamFileEventSource: WorktreeFileEventSource, @unchecked Sendable {
  private let onBatch: @Sendable ([String]) -> Void
  private let queue: DispatchQueue
  private var stream: FSEventStreamRef?

  init(paths: [URL], latency: TimeInterval, onBatch: @escaping @Sendable ([String]) -> Void) {
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
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf
    )
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
      guard let info else { return }
      let source = Unmanaged<FSEventStreamFileEventSource>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
      if !paths.isEmpty {
        source.onBatch(paths)
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

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit {
    stop()
  }
}

/// Default live factory used by `WorktreeInfoWatcherManager`.
let liveWorktreeFileEventSourceFactory: WorktreeFileEventSourceFactory = { paths, latency, onBatch in
  FSEventStreamFileEventSource(paths: paths, latency: latency, onBatch: onBatch)
}
```

- [ ] **Step 2: Build**

Run: `make build-app`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add cherrylily/Clients/FileEvents/FSEventStreamFileEventSource.swift
git commit -m "feat: add FSEventStream-backed file event source"
```

---

### Task 7: Inject the file-event source into `WorktreeInfoWatcherManager` and drive `.filesChanged` from working-tree edits

Add a per-worktree content watcher (FSEvents on the working directory). On a batch: map to paths relative to the worktree, drop ignored/`.git` paths, and if anything survives, run the existing `scheduleFilesChanged` debounce. Keep the existing `.git/HEAD` `DispatchSource` (it still drives `.branchChanged`). Remove the blind per-worktree line-change *polling* loop.

**Files:**
- Modify: `cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift`
- Test: `cherrylilyTests/WorktreeInfoWatcherManagerTests.swift` (add cases + a fake source)

- [ ] **Step 1: Write the failing tests**

Add a fake source the test controls, plus an injectable factory. Append to the test file:

```swift
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
```

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test … -only-testing:cherrylilyTests/WorktreeInfoWatcherManagerTests/filesChangedFiresOnNonIgnoredWorktreeEdit …`
Expected: FAIL — `fileEventSourceFactory:` init param does not exist.

- [ ] **Step 3: Implement**

In `WorktreeInfoWatcherManager.swift`:

3a. Add stored properties near `:35-51`:

```swift
  private let fileEventSourceFactory: WorktreeFileEventSourceFactory
  private let contentWatchLatency: TimeInterval
  private var contentSources: [Worktree.ID: WorktreeFileEventSource] = [:]
  private var ignoreMatchers: [Worktree.ID: GitIgnorePrefixMatcher] = [:]
```

3b. Extend the init signature (`:53-66`) — add params with live defaults:

```swift
  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    filesChangedDebounceInterval: Duration = .seconds(5),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    contentWatchLatency: TimeInterval = 0.7,
    fileEventSourceFactory: @escaping WorktreeFileEventSourceFactory = liveWorktreeFileEventSourceFactory,
    clock: C = ContinuousClock()
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.filesChangedDebounceInterval = filesChangedDebounceInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.contentWatchLatency = contentWatchLatency
    self.fileEventSourceFactory = fileEventSourceFactory
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
  }
```

3c. In `configureWatcher(for:)` (`:163-178`), after `startWatcher(...)`, also start the content source. Append before the closing brace of the method:

```swift
    startContentSource(for: worktree)
```

3d. Add the content-source methods (place after `startWatcher`):

```swift
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
```

3e. In `stopWatcher(for:)` (`:282-288`) add cleanup:

```swift
    contentSources.removeValue(forKey: worktreeID)?.stop()
    ignoreMatchers.removeValue(forKey: worktreeID)
```

3f. In `stopAll()` (`:290-322`) add, alongside the other teardown loops:

```swift
    for source in contentSources.values {
      source.stop()
    }
    contentSources.removeAll()
    ignoreMatchers.removeAll()
```

3g. **Remove the blind line-change polling loop.** Replace `updateLineChangeSchedule(...)` (`:400-421`) so it only emits the immediate refresh and never starts a repeating task:

```swift
  private func updateLineChangeSchedule(
    worktreeID: Worktree.ID,
    immediate: Bool,
    forceReschedule: Bool = false
  ) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    lineChangeTasks.removeValue(forKey: worktreeID)?.task.cancel()
    let shouldEmit = immediate && !deferredLineChangeIDs.contains(worktreeID)
    guard shouldEmit else {
      return
    }
    deferredLineChangeIDs.remove(worktreeID)
    emit(.filesChanged(worktreeID: worktreeID))
  }
```

> The `forceReschedule` parameter is now unused but kept so call sites (`:242-246`) compile unchanged. The repeating `updateRepeatingTask` helper (`:423-455`) is now only used by line changes — leave it in place for now; it becomes dead after this task and is removed in Task 8.

3h. In `scheduleFilesChanged` (`:232-251`), the branch that calls `updateLineChangeSchedule(..., forceReschedule: true)` still works (now a no-op repeating-wise but still emits via the debounce's own `emit(.filesChanged)`). No change needed.

- [ ] **Step 4: Run tests to verify they pass**

Run both new tests and the existing suite:
`xcodebuild test … -only-testing:cherrylilyTests/WorktreeInfoWatcherManagerTests …`
Expected: PASS, including the pre-existing tests (`emitsLineChangesImmediatelyOnInitialWorktreeLoad`, `defersLineChangesForWorktreesAddedAfterInitialLoad`, the two cooldown tests).

> If `defersLineChangesForWorktreesAddedAfterInitialLoad` fails: it asserts the deferred worktree emits after the 80 ms *interval*. With polling removed, the deferred emit now happens when the worktree becomes non-deferred via a files event or selection, not via a timer. Update that test to drive the emit by selecting the worktree (`manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))`) instead of advancing the clock, and assert the single emit. Make this edit in the same step.

- [ ] **Step 5: Build**

Run: `make build-app`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift cherrylilyTests/WorktreeInfoWatcherManagerTests.swift
git commit -m "feat: drive +/- pill from FSEvents instead of polling"
```

---

### Task 8: Remove now-dead line-change repeating machinery

After Task 7, `lineChangeTasks` + `updateRepeatingTask` are no longer needed for line changes.

**Files:**
- Modify: `cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift`

- [ ] **Step 1: Delete dead code**

Remove the `updateRepeatingTask(_:tasks:)` method (`:423-455`) and the `RepeatingTaskRequest` struct (`:22-28`) **only if** no remaining caller references them. (Phase C reuses neither — PR scheduling is rewritten there.) Remove the `lineChangeTasks` property and its references in `stopWatcher`/`stopAll`. Replace the body of `updateLineChangeSchedule` to drop the `lineChangeTasks.removeValue` line added in Task 7 (no longer exists).

- [ ] **Step 2: Build + full watcher tests**

Run: `make build-app` then
`xcodebuild test … -only-testing:cherrylilyTests/WorktreeInfoWatcherManagerTests …`
Expected: build succeeds; all watcher tests PASS.

- [ ] **Step 3: Commit**

```bash
git add cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift
git commit -m "refactor: remove dead line-change polling machinery"
```

---

## Phase C — PR: ref-trigger + SHA dedupe + focused-only discovery

### Task 9: Add `repositoryRefsChanged` event

A new event the manager emits when refs move (commit/push). The reducer will SHA-dedupe it before any `gh` call.

**Files:**
- Modify: `cherrylily/Clients/WorktreeInfoWatcher/WorktreeInfoWatcherClient.swift` (`Event` enum `:15-19`)

- [ ] **Step 1: Add the case**

```swift
  enum Event: Equatable {
    case branchChanged(worktreeID: Worktree.ID)
    case filesChanged(worktreeID: Worktree.ID)
    case repositoryRefsChanged(repositoryRootURL: URL, worktreeIDs: [Worktree.ID])
    case repositoryPullRequestRefresh(repositoryRootURL: URL, worktreeIDs: [Worktree.ID])
  }
```

- [ ] **Step 2: Build**

Run: `make build-app`
Expected: FAIL — the reducer's `switch event` (`:1994`) is now non-exhaustive. This is expected; Task 11 adds the handler. To keep the build green between tasks, add a temporary passthrough now in `RepositoriesFeature.swift` at the top of the `switch event` block:

```swift
        case .repositoryRefsChanged:
          return .none
```

Re-run `make build-app`. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add cherrylily/Clients/WorktreeInfoWatcher/WorktreeInfoWatcherClient.swift cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift
git commit -m "feat: add repositoryRefsChanged event (passthrough)"
```

---

### Task 10: Per-repo refs watcher + focused-only discovery; remove blind PR polling

Add one FSEvents source per repository watching the common git dir's refs, emitting `repositoryRefsChanged`. Replace the per-repo blind PR loop with a single discovery loop that runs **only for the focused repo** at a slow interval. Fire `repositoryRefsChanged` from the existing HEAD `DispatchSource` too (branch switch moves SHA).

**Files:**
- Modify: `cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift`
- Modify: `cherrylily/Clients/Git/GitClient.swift` — add `gitCommonDir(for:)`
- Test: `cherrylilyTests/WorktreeInfoWatcherManagerTests.swift`

- [ ] **Step 1: Add `GitClient.gitCommonDir` (with test)**

Add to `GitOperation`: `case gitCommonDir = "git_common_dir"`. Add method:

```swift
  nonisolated func gitCommonDir(for repositoryRootURL: URL) async -> URL? {
    let path = repositoryRootURL.path(percentEncoded: false)
    guard
      let output = try? await runGit(
        operation: .gitCommonDir,
        arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
      )
    else {
      return nil
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
  }
```

Test `cherrylilyTests/GitClientCommonDirTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct GitClientCommonDirTests {
  @Test func returnsAbsoluteCommonDir() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        #expect(arguments.contains("--git-common-dir"))
        return ShellOutput(stdout: "/repo/.git\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let client = GitClient(shell: shell, capabilities: GitCapabilities(shell: shell))
    let url = await client.gitCommonDir(for: URL(fileURLWithPath: "/repo/wt"))
    #expect(url?.path(percentEncoded: false) == "/repo/.git")
  }
}
```

Run that test; expect PASS. Commit:
```bash
git add cherrylily/Clients/Git/GitClient.swift cherrylilyTests/GitClientCommonDirTests.swift
git commit -m "feat: add GitClient.gitCommonDir"
```

- [ ] **Step 2: Write the failing manager test (refs watcher emits)**

The refs watcher resolves the common dir asynchronously via an injected git-common-dir resolver. To keep the manager testable without a real git, inject a resolver closure (defaulting to the live `GitClient().gitCommonDir`).

```swift
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
    await drainAsyncEvents(160)
    let baseline = await collector.repositoryRefsChangedCount(repositoryRootURL: repo.tempRoot)

    let pushed = commonDir.appending(path: "refs/remotes/origin/sparrow").path(percentEncoded: false)
    await registry.source(watching: commonDir)?.onBatch([pushed])
    await drainAsyncEvents(160)

    #expect(await collector.repositoryRefsChangedCount(repositoryRootURL: repo.tempRoot) == baseline + 1)
    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: repo.tempRoot)
  }
```

Add a counter to `EventCollector`:

```swift
  func repositoryRefsChangedCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryRefsChanged(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:cherrylilyTests/WorktreeInfoWatcherManagerTests/refsChangeEmitsRepositoryRefsChanged …`
Expected: FAIL — `gitCommonDirResolver:` param undefined.

- [ ] **Step 4: Implement refs watcher + discovery rewrite**

4a. Add stored props:

```swift
  private let gitCommonDirResolver: @Sendable (URL) async -> URL?
  private var refsSources: [URL: WorktreeFileEventSource] = [:]
  private var refsCommonDirByRepository: [URL: URL] = [:]
```

4b. Add init param (after `fileEventSourceFactory`, before `clock`), with live default:

```swift
    gitCommonDirResolver: @escaping @Sendable (URL) async -> URL? = { await GitClient().gitCommonDir(for: $0) },
```
and `self.gitCommonDirResolver = gitCommonDirResolver` in the body.

4c. In `setWorktrees`, where it iterates `repositoryRoots` to call `updatePullRequestSchedule` (`:115-118`), also ensure a refs watcher exists:

```swift
    for repositoryRootURL in repositoryRoots {
      ensureRefsWatcher(repositoryRootURL: repositoryRootURL)
      updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
    }
```

4d. Add refs-watcher methods:

```swift
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
```

4e. Fire refs-changed on branch switch too. In `scheduleBranchChanged` (`:220-230`), after `self?.emit(.branchChanged(...))`, add:

```swift
        if let repositoryRootURL = self?.worktrees[worktreeID]?.repositoryRootURL {
          self?.emitRefsChanged(repositoryRootURL: repositoryRootURL)
        }
```

4f. **Rewrite `updatePullRequestSchedule`** (`:343-379`) to a focused-repo-only slow discovery loop. Add a `discoveryInterval` (e.g. `.seconds(150)`) — add it as an init param with default `.seconds(150)` and store it. New body:

```swift
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
    // that have no local ref signal). Background repos refresh on ref events + focus only.
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
```

4g. Clean up refs sources in `stopWatcher`/`stopAll`. In `stopAll`, add:

```swift
    for source in refsSources.values { source.stop() }
    refsSources.removeAll()
    refsCommonDirByRepository.removeAll()
```

In `setWorktrees`, when removing obsolete repositories (`:119-122`), also stop refs sources:

```swift
    for repositoryRootURL in obsoleteRepositories {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      refsSources.removeValue(forKey: repositoryRootURL)?.stop()
      refsCommonDirByRepository.removeValue(forKey: repositoryRootURL)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run the full watcher suite. Expected: PASS, including `refsChangeEmitsRepositoryRefsChanged` and the existing cooldown tests.

> The cooldown tests assert `pullRequestRefreshCount == baseline + 1` on selection. With discovery now focused-only, selecting a worktree still calls `updatePullRequestSchedule(immediate: shouldImmediatelyRefreshPullRequests(...))`, which emits one refresh — behavior preserved. If a cooldown test now sees an extra/missing emit, adjust the expectation to match the focused-only emit (one per selection through cooldown), keeping the cooldown semantics.

- [ ] **Step 6: Build + commit**

```bash
make build-app
git add cherrylily/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift cherrylilyTests/WorktreeInfoWatcherManagerTests.swift
git commit -m "feat: refs-triggered PR refresh + focused-only discovery"
```

---

### Task 11: Reducer SHA dedupe for `repositoryRefsChanged`

Compute each worktree's head SHA; refresh PRs only for worktrees whose SHA moved since the last successful fetch.

**Files:**
- Modify: `cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift` (state + the `repositoryRefsChanged` case added in Task 9)
- Test: `cherrylilyTests/RepositoriesFeaturePRDedupeTests.swift`

- [ ] **Step 1: Add state field**

Near the other PR-tracking state (search for `inFlightPullRequestRefreshRepositoryIDs`), add:

```swift
    var lastFetchedHeadSHAByWorktreeID: [Worktree.ID: String] = [:]
```

- [ ] **Step 2: Write the failing reducer test**

Uses the existing `makeState` / `makeWorktree` / `makeRepository` helpers from `RepositoriesFeatureTests.swift` (copy them into this file or make them `internal` and shared). Overrides only the `headSHA` closure on the dependency, and sets `githubIntegrationAvailability = .disabled` so the downstream `repositoryPullRequestRefresh` returns `.none` (no real `gh`/network) while we still observe that the action was dispatched.

```swift
import ComposableArchitecture
import Foundation
import Testing

@testable import CherryLily

@MainActor
struct RepositoriesFeaturePRDedupeTests {
  @Test func refsChangedTriggersRefreshOnlyForMovedSHA() async throws {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.githubIntegrationAvailability = .disabled
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.headSHA = { _ in "sha-NEW" }
    }
    store.exhaustivity = .off

    await store.send(.worktreeInfoEvent(.repositoryRefsChanged(
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      worktreeIDs: [worktree.id]
    )))

    await store.receive(\.headSHAsUpdated)
    await store.receive { action in
      if case .worktreeInfoEvent(.repositoryPullRequestRefresh) = action { return true }
      return false
    }
    #expect(store.state.lastFetchedHeadSHAByWorktreeID[worktree.id] == "sha-NEW")
  }

  @Test func refsChangedSkipsRefreshWhenSHAUnchanged() async throws {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.githubIntegrationAvailability = .disabled
    initial.lastFetchedHeadSHAByWorktreeID[worktree.id] = "sha-SAME"
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.headSHA = { _ in "sha-SAME" }
    }
    // Full exhaustivity: SHA unchanged means the ONLY action received is headSHAsUpdated
    // (no state change since the SHA is identical). A stray PR refresh would fail teardown.
    await store.send(.worktreeInfoEvent(.repositoryRefsChanged(
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      worktreeIDs: [worktree.id]
    )))

    await store.receive(\.headSHAsUpdated)
  }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:cherrylilyTests/RepositoriesFeaturePRDedupeTests …`
Expected: FAIL — `repositoryRefsChanged` currently returns `.none` (Task 9 passthrough).

- [ ] **Step 4: Implement the handler**

Replace the Task 9 passthrough `case .repositoryRefsChanged: return .none` with:

```swift
        case .repositoryRefsChanged(let repositoryRootURL, let worktreeIDs):
          let worktrees = worktreeIDs.compactMap { state.worktree(for: $0) }
          guard !worktrees.isEmpty else { return .none }
          let gitClient = gitClient
          let previousSHAs = state.lastFetchedHeadSHAByWorktreeID
          return .run { send in
            var moved: [Worktree.ID] = []
            var updated: [Worktree.ID: String] = [:]
            for worktree in worktrees {
              guard let sha = await gitClient.headSHA(worktree.workingDirectory) else { continue }
              updated[worktree.id] = sha
              if previousSHAs[worktree.id] != sha {
                moved.append(worktree.id)
              }
            }
            await send(.headSHAsUpdated(updated))
            guard !moved.isEmpty else { return }
            await send(.worktreeInfoEvent(.repositoryPullRequestRefresh(
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: moved
            )))
          }
          .cancellable(id: CancelID.refsDedupe(repositoryRootURL), cancelInFlight: true)
```

Add the action (near `worktreeLineChangesLoaded` `:219`):

```swift
    case headSHAsUpdated([Worktree.ID: String])
```

Handle it (near `worktreeLineChangesLoaded` handler `:2170`):

```swift
      case .headSHAsUpdated(let shasByWorktreeID):
        for (worktreeID, sha) in shasByWorktreeID {
          state.lastFetchedHeadSHAByWorktreeID[worktreeID] = sha
        }
        return .none
```

Add the cancel ID (find the `CancelID` enum, near `lineChanges(_:)` `:17`):

```swift
    static func refsDedupe(_ repositoryRootURL: URL) -> String {
      "repositories.refsDedupe.\(repositoryRootURL.path(percentEncoded: false))"
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Step 3 command. Expected: PASS (2 tests).

- [ ] **Step 6: Build + commit**

```bash
make build-app
git add cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift cherrylilyTests/RepositoriesFeaturePRDedupeTests.swift
git commit -m "feat: SHA-dedupe PR refresh on ref changes"
```

---

### Task 12: Prune obsolete head-SHA state when worktrees disappear

Avoid unbounded growth of `lastFetchedHeadSHAByWorktreeID`. Implemented as a pure helper called wherever repositories are applied, so the test does not depend on a specific removal action.

**Files:**
- Modify: `cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift`
- Test: `cherrylilyTests/RepositoriesFeaturePRDedupeTests.swift` (extend)

- [ ] **Step 1: Write failing test for the pure helper**

```swift
  @Test func pruneHeadSHAsDropsMissingWorktrees() {
    let kept = Worktree.ID("/tmp/repo/keep")
    let removed = Worktree.ID("/tmp/repo/gone")
    let result = pruneHeadSHAs(
      [kept: "a", removed: "b"],
      liveWorktreeIDs: [kept]
    )
    #expect(result == [kept: "a"])
  }
```

> `Worktree.ID` is a string-backed ID (worktree IDs are paths, e.g. `"/tmp/repo/keep"` in `makeWorktree`). If `Worktree.ID` is a typealias for `String`, the `Worktree.ID("…")` initializer works directly; if it is a wrapper, use its literal form as the existing tests do.

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL — `pruneHeadSHAs` undefined.

- [ ] **Step 3: Implement the helper + call site**

Add the pure helper near the other top-level helpers in `RepositoriesFeature.swift`:

```swift
func pruneHeadSHAs(
  _ shas: [Worktree.ID: String],
  liveWorktreeIDs: Set<Worktree.ID>
) -> [Worktree.ID: String] {
  shas.filter { liveWorktreeIDs.contains($0.key) }
}
```

Call it where the new worktree/repository set is committed to state (search `applyRepositories`, after `state.repositories` is assigned). Compute live IDs from the same `state.repositories` traversal already used nearby:

```swift
        let liveWorktreeIDs = Set(state.repositories.flatMap { $0.worktrees.map(\.id) })
        state.lastFetchedHeadSHAByWorktreeID = pruneHeadSHAs(
          state.lastFetchedHeadSHAByWorktreeID,
          liveWorktreeIDs: liveWorktreeIDs
        )
```

> Verify the property path `repository.worktrees` against the `Repository` model (it is an `IdentifiedArrayOf<Worktree>` per the architecture notes). Adjust the flatMap accessor if the model nests worktrees differently, keeping the resulting `Set<Worktree.ID>`.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.

- [ ] **Step 5: Build + commit**

```bash
make build-app
git add cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift cherrylilyTests/RepositoriesFeaturePRDedupeTests.swift
git commit -m "feat: prune head-SHA cache for removed worktrees"
```

---

### Task 13: Manual integration smoke (no automated test)

Confirm the end-to-end event flow on a real repo. Per memory, CherryLily IS the user's terminal — **run the dev build, do not kill the running app or tmux**; launch a separate Debug instance.

**Files:** none.

- [ ] **Step 1:** `make build-app` then launch the Debug build (`make run-app`) as a separate instance.
- [ ] **Step 2:** Open a repo with a worktree. Edit a tracked file in that worktree from an external editor; confirm the `+/-` pill updates within ~1–2 s without a 30 s wait.
- [ ] **Step 3:** Touch a file under `node_modules/` (or another top-level ignored dir); confirm the pill does **not** thrash (no visible churn).
- [ ] **Step 4:** Commit, then push the branch; confirm the PR status refreshes shortly after the push (ref-triggered), not only on the slow timer.
- [ ] **Step 5:** Leave the app idle for 2 min on a non-focused repo; confirm (via `make log-stream`) no periodic `git diff` / `gh` spawns for background worktrees.
- [ ] **Step 6:** Note results in the PR description. No commit.

---

## Phase D — Exponential backoff

### Task 14: GitHub-availability recovery uses exponential backoff

Replace the fixed `githubIntegrationRecoveryInterval` retry loop (`RepositoriesFeature.swift:2116-2125`) with capped exponential backoff.

**Files:**
- Modify: `cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift`
- Test: `cherrylilyTests/RepositoriesFeatureBackoffTests.swift`

- [ ] **Step 1: Add a pure backoff helper + test**

Add near the top-level helpers in `RepositoriesFeature.swift`:

```swift
/// Capped exponential backoff: base * 2^attempt, clamped to max.
func githubRecoveryBackoff(attempt: Int, base: Duration = .seconds(15), max: Duration = .seconds(300)) -> Duration {
  let multiplier = 1 << Swift.min(attempt, 16)
  let scaled = base * multiplier
  return scaled < max ? scaled : max
}
```

Test `cherrylilyTests/RepositoriesFeatureBackoffTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct RepositoriesFeatureBackoffTests {
  @Test func backoffDoublesThenCaps() {
    #expect(githubRecoveryBackoff(attempt: 0) == .seconds(15))
    #expect(githubRecoveryBackoff(attempt: 1) == .seconds(30))
    #expect(githubRecoveryBackoff(attempt: 2) == .seconds(60))
    #expect(githubRecoveryBackoff(attempt: 10) == .seconds(300))
  }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL — helper undefined.

- [ ] **Step 3: Implement the loop change.** Replace the recovery loop body (`:2116-2125`) with an attempt-counting backoff:

```swift
          return .run { send in
            var attempt = 0
            while !Task.isCancelled {
              try? await ContinuousClock().sleep(for: githubRecoveryBackoff(attempt: attempt))
              guard !Task.isCancelled else { return }
              attempt += 1
              await send(.refreshGithubIntegrationAvailability)
            }
          }
          .cancellable(id: CancelID.githubIntegrationRecovery, cancelInFlight: true)
```

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.

- [ ] **Step 5: Build + commit**

```bash
make build-app
git add cherrylily/Features/Repositories/Reducer/RepositoriesFeature.swift cherrylilyTests/RepositoriesFeatureBackoffTests.swift
git commit -m "feat: exponential backoff for GitHub availability recovery"
```

---

## Final verification

- [ ] **Run the full test suite:** `make test`. Expected: all green.
- [ ] **Lint + format:** `make check`. Fix any findings (do not disable rules).
- [ ] **Build:** `make build-app`. Expected: succeeds.
- [ ] **Open a PR** (per `CLAUDE.md`, branch `pwason/gitstatusd` is non-generic). Summarize the before/after resource numbers from the spec in the PR body.

---

## Notes / Out of Scope (do not implement here)

- `wt ls --json` 30 s rediscovery (PERF.md S6, AppFeature scenePhase timer) — separate follow-up.
- Unifying the two watchers via a git custom fsmonitor hook provider.
- PERF.md ranks 1–5 (UI write-amplification) — unrelated to this change.
