# Session Persistence — Phase 5: Edge Cases + Robustness

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md`
**Phase 1-4 already implemented.**

**Goal:** Harden session persistence against real-world failure modes — hourly autosave so unexpected exits don't lose data, tmux crash recovery so a backend hiccup doesn't take down all terminals, disk-full alerts so capture failures surface to the user, and single-instance enforcement so two CherryLily windows don't corrupt the shared socket.

**Architecture:** Add `HourlyAutosaveTimer` (DispatchSourceTimer driven by setting), extend `SessionPersistence` with a `tmuxIsAlive()` health check and `restartIfNeeded()` recovery path, add `MultiInstanceGuard` using NSDistributedNotificationCenter to detect/decline secondary launches.

**Tech Stack:** Swift 6.2, DispatchSourceTimer, NSDistributedNotificationCenter.

---

## Task 1: Hourly autosave timer

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/HourlyAutosaveTimer.swift`
- Create: `cherrylilyTests/HourlyAutosaveTimerTests.swift`
- Modify: `cherrylily/App/supacodeApp.swift` — construct and start timer
- Modify: `cherrylily/Features/Settings/Views/SessionsSettingsView.swift` — re-enable toggle, update description

`HourlyAutosaveTimer` schedules a `DispatchSourceTimer` (with `.strict` flag so it doesn't drift in app-nap) that calls `SessionPersistence.captureAll(for: <built layout>)` every hour. Reads enable/disable from `@Shared(.settingsFile).global.hourlyAutosaveEnabled`. On toggle off, cancels the timer. On toggle on, restarts.

- [ ] **Step 1: TDD test**

Test the timer state transitions only (not the actual 1-hour interval — use injectable interval for tests). Pattern:

```swift
@Test func startSchedulesFireAfterIntervalAndCapturesLayout() async throws { ... }
@Test func stopCancelsPendingFire() async throws { ... }
@Test func updateEnabledRestartsWhenFlipped() async throws { ... }
```

- [ ] **Step 2: Implementation**

```swift
@MainActor
final class HourlyAutosaveTimer {
  private let persistence: SessionPersistence
  private let snapshot: @MainActor () -> SessionLayout?
  private let scrollbackLimit: @MainActor () -> Int?
  private let interval: DispatchTimeInterval
  private var timer: DispatchSourceTimer?

  init(persistence: SessionPersistence,
       interval: DispatchTimeInterval = .seconds(3600),
       snapshot: @escaping @MainActor () -> SessionLayout?,
       scrollbackLimit: @escaping @MainActor () -> Int?) { ... }

  func start() { ... }   // creates timer, schedules first fire at +interval
  func stop() { ... }    // cancels + nils
  func updateEnabled(_ enabled: Bool) { ... }
}
```

Timer handler:
```swift
timer.setEventHandler { [weak self] in
  guard let self else { return }
  Task { @MainActor in
    guard let layout = self.snapshot() else { return }
    let limit = self.scrollbackLimit()
    _ = await self.persistence.captureAll(for: layout, scrollbackLimit: limit)
  }
}
```

Use `.strict` flag: `timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))` — leeway lets the OS batch but caps drift.

- [ ] **Step 3: Wire from supacodeApp**

After `loadLayoutOnLaunch`, construct the timer with closures that snapshot current state. Subscribe to settings changes via TCA delegate or just check on each fire.

- [ ] **Step 4: Re-enable the toggle**

In `SessionsSettingsView`, remove `.disabled(true)` and restore "In case CherryLily exits unexpectedly." caption.

- [ ] **Step 5: Build + test + commit**

```bash
make test 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED"
git add ...; git commit -m "Add HourlyAutosaveTimer driving SessionPersistence.captureAll"
```

---

## Task 2: tmux health check + crash auto-recovery

**Files:**
- Modify: `cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift` — add `ping() async throws` (cheap `tmux ls`)
- Modify: `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift` — add `tmuxIsAlive() async -> Bool` wrapper
- Create: `cherrylily/Features/Sessions/BusinessLogic/TmuxHealthMonitor.swift` — polls every 10s; on death, logs + fires onCrash callback
- Modify: `cherrylily/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — recover by signaling each WTS to recreate its surfaces (which will hit a fresh tmux server next launch attempt)

Per spec (line 339-351): "auto-restart-and-replay". Detection trigger: tmux socket missing or `tmux ls` fails twice in a row. Recovery:
1. Mark all surfaces "reconnecting" (UI banner)
2. Spawn new tmux server (next `new-session` call does this implicitly)
3. Recreate all sessions per live layout
4. Replay last scrollback file for each

For phase 5 scope: ship the **detection** + **logging**, defer full automated recreation to a follow-up (it's a UX problem more than a wiring problem at this stage). Add the onCrash callback so future work can hook UI.

- [ ] **Step 1: Add ping to TmuxClient**

```swift
/// Cheap health check — exit 0 iff the tmux server is reachable.
/// "No server running" still counts as alive-for-our-purposes (we lazily
/// start servers on session creation), so it returns true.
func ping() async -> Bool {
  do {
    _ = try await listSessionNames()
    return true
  } catch {
    return false  // command failed for non-cleanup-tolerated reasons
  }
}
```

- [ ] **Step 2: TmuxHealthMonitor**

```swift
final class TmuxHealthMonitor: Sendable {
  private let tmuxClient: TmuxClient
  private let interval: TimeInterval
  private let onCrash: @Sendable () -> Void
  private var task: Task<Void, Never>?
  // 2-failures-in-a-row to avoid one-shot flake

  func start() {
    task = Task { [weak self] in
      var consecutiveFailures = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        let alive = await tmuxClient.ping()
        if alive { consecutiveFailures = 0; continue }
        consecutiveFailures += 1
        if consecutiveFailures >= 2 { onCrash(); break }
      }
    }
  }

  func stop() { task?.cancel() }
}
```

- [ ] **Step 3: Wire from supacodeApp**

Construct + start in init (only when persistence enabled). onCrash callback logs warning and posts a SupaLogger note for now — wiring UI banner is future Phase 6 polish.

- [ ] **Step 4: Test + commit**

```swift
@Test func detectsCrashAfterTwoConsecutiveFailures() async { ... }
@Test func consecutivePassResetsCounter() async { ... }
```

---

## Task 3: Disk-full alert on capture failure

**Files:**
- Modify: `cherrylily/Features/Sessions/BusinessLogic/SessionPersistence.swift` — distinguish disk-full from other capture errors; expose via callback or error
- Modify: `cherrylily/App/supacodeApp.swift` — wire one-time alert presentation when disk-full is observed

Per spec line 298: "Log; mark file as failed; show one-time alert 'Could not save terminal contents — disk full.' Persistence remains enabled but stale-file warnings appear."

Detection: `ScrollbackStore.write` throws `POSIXError(.ENOSPC)` or similar.

- [ ] **Step 1: Detect ENOSPC inside captureOne, emit a structured outcome**

Return an enum from captureOne: `.success`, `.failed(reason)`. Aggregate in captureAll.

- [ ] **Step 2: Bubble disk-full up to the app delegate**

When applicationWillTerminate's captureAll completes with any disk-full failures, post a UserDefaults flag. On next launch, supacodeApp checks the flag and shows an `NSAlert` once.

- [ ] **Step 3: Tests**

```swift
@Test func captureOneReportsDiskFullSpecifically() async throws { ... }
```

(Mock the scrollback store to throw ENOSPC.)

- [ ] **Step 4: Commit**

---

## Task 4: Multi-instance prevention

**Files:**
- Modify: `cherrylily/App/supacodeApp.swift` — `applicationDidFinishLaunching` checks for an existing CherryLily process; if found, foreground it and quit self
- Possibly: `cherrylily/App/AppDelegate+MultiInstance.swift` (split for clarity)

Per spec line 300: "prevent multi-instance via `NSApplicationDelegate.applicationShouldHandleReopen` (already done for window management)". But the existing implementation doesn't reject SECOND instances — it just brings the existing window forward when reopened from Finder. A second `open -n` bypasses that.

The simplest robust approach: use NSDistributedNotificationCenter to broadcast a "I'm launching" notification; the existing instance replies. If second instance gets a reply within 200ms, it knows another instance is running and terminates itself (asking the other to foreground).

- [ ] **Step 1: Define notification names**

```swift
extension Notification.Name {
  static let cherryLilyInstanceProbe = Notification.Name("app.supabit.cherrylily.instanceProbe")
  static let cherryLilyInstanceAck   = Notification.Name("app.supabit.cherrylily.instanceAck")
}
```

- [ ] **Step 2: Probe at startup**

In `applicationDidFinishLaunching`, BEFORE constructing terminal manager:
1. Subscribe to `cherryLilyInstanceAck`
2. Post `cherryLilyInstanceProbe`
3. Wait 200ms via RunLoop
4. If ack received → bring other to front, `NSApp.terminate(self)`
5. If no ack → we're the primary; subscribe to `cherryLilyInstanceProbe` and ACK on receipt

This needs to happen BEFORE we touch the tmux socket or session files.

- [ ] **Step 3: Test (manual, won't dispatch from this session)**

`open -n /Applications/CherryLily.app` from terminal should bring the existing instance forward instead of launching a second copy.

- [ ] **Step 4: Commit**

---

## Task 5: Lint + push

- [ ] Lint check on Phase 5 files only
- [ ] Push commits to origin
