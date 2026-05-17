import Observation
import Sharing

private let terminalLogger = SupaLogger("Terminal")

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime
  let persistenceEnabled: @Sendable () -> Bool
  let persistence: SessionPersistence?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  /// Layout read on app launch via `loadLayoutOnLaunch()`. Consulted whenever
  /// `state(for:)` creates a new WTS so the restored worktree comes back with
  /// its previous tabs. Held in-memory to avoid re-reading the disk per worktree.
  private var cachedLayout: SessionLayout?
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  var selectedWorktreeID: Worktree.ID?

  init(
    runtime: GhosttyRuntime,
    persistenceEnabled: @escaping @Sendable () -> Bool = { false },
    persistence: SessionPersistence? = nil,
  ) {
    self.runtime = runtime
    self.persistenceEnabled = persistenceEnabled
    self.persistence = persistence
  }

  /// Called once at app launch (from `CherryLilyApp.init`). Reads the persisted layout
  /// into memory so per-worktree `state(for:)` calls can consult it without re-reading
  /// the disk. A nil result (no file, corrupt file, or persistence disabled) means
  /// "no restoration" — worktrees come back empty as before.
  func loadLayoutOnLaunch() {
    guard let persistence else { return }
    do {
      cachedLayout = try persistence.restoreLayout()
    } catch {
      SupaLogger("Sessions").warning("layout read on launch failed: \(error)")
      cachedLayout = nil
    }
  }

  /// Cached layout exposed for one-time use during app-launch reconciliation.
  /// Returns `nil` if `loadLayoutOnLaunch()` hasn't been called yet, or if no layout
  /// file existed, or if the load failed.
  var loadedLayout: SessionLayout? { cachedLayout }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew) }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, initialInput: input)
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .runScript(let worktree, let script):
      _ = state(for: worktree).runScript(script)
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .runBlockingScript(let worktree, let kind, let script):
      _ = state(for: worktree).runBlockingScript(kind: kind, script)
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .closeTab(let worktreeID, let tabID):
      closeTab(worktreeID: worktreeID, tabID: tabID)
    case .closeOtherTabs(let worktreeID, let keepingTabID):
      closeOtherTabs(worktreeID: worktreeID, keepingTabID: keepingTabID)
    case .closeTabsToRight(let worktreeID, let ofTabID):
      closeTabsToRight(worktreeID: worktreeID, ofTabID: ofTabID)
    case .focusTab(let worktreeID, let tabID):
      focusTab(worktreeID: worktreeID, tabID: tabID)
    default:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    default:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
      }
      selectedWorktreeID = id
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    default:
      return
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: TerminalClient.Event.self)
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  /// Read-only snapshot of all (worktreeID, state) pairs. Used by LayoutSnapshotBuilder.
  var allWorktreeStates: [(Worktree.ID, WorktreeTerminalState)] {
    states.map { ($0.key, $0.value) }
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: worktree,
      runSetupScript: runSetupScript,
      persistenceEnabled: { [weak self] in self?.persistenceEnabled() ?? false }
    )
    state.setNotificationsEnabled(notificationsEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] title, body in
      self?.emit(.notificationReceived(worktreeID: worktree.id, title: title, body: body))
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
    }
    state.onRequestCloseTab = { [weak self] tabID in
      self?.emit(.tabCloseRequested(worktreeID: worktree.id, tabID: tabID))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTabFocusChanged = { [weak self] tabID in
      self?.emit(.tabFocusChanged(worktreeID: worktree.id, tabID: tabID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    state.onRunScriptStatusChanged = { [weak self] isRunning in
      self?.emit(.runScriptStatusChanged(worktreeID: worktree.id, isRunning: isRunning))
    }
    state.onBlockingScriptCompleted = { [weak self] kind, exitCode in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    states[worktree.id] = state
    if let cachedLayout,
      let persistedWorktree = cachedLayout.worktrees.first(where: { $0.worktreeID == worktree.id })
    {
      state.restoreTabs(from: persistedWorktree)
    }
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    if state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    _ = state.createTab(setupScript: setupScript, initialInput: initialInput)
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func focusTab(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    guard let state = states[worktreeID] else { return }
    guard state.tabManager.tabs.contains(where: { $0.id == tabID }) else { return }
    state.selectTab(tabID)
  }

  func closeTab(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    guard let state = states[worktreeID] else { return }
    guard state.tabManager.tabs.contains(where: { $0.id == tabID }) else { return }
    state.closeTab(tabID)
  }

  func closeOtherTabs(worktreeID: Worktree.ID, keepingTabID: TerminalTabID) {
    guard let state = states[worktreeID] else { return }
    guard state.tabManager.tabs.contains(where: { $0.id == keepingTabID }) else { return }
    state.closeOtherTabs(keeping: keepingTabID)
  }

  func closeTabsToRight(worktreeID: Worktree.ID, ofTabID: TerminalTabID) {
    guard let state = states[worktreeID] else { return }
    guard state.tabManager.tabs.contains(where: { $0.id == ofTabID }) else { return }
    state.closeTabsToRight(of: ofTabID)
  }

  func tabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    guard let state = states[worktreeID] else { return false }
    return state.tabManager.tabs.contains(where: { $0.id == tabID })
  }

  func tabTitle(worktreeID: Worktree.ID, tabID: TerminalTabID) -> String? {
    states[worktreeID]?.tabManager.tabs.first(where: { $0.id == tabID })?.title
  }

  func tabCount(worktreeID: Worktree.ID) -> Int {
    states[worktreeID]?.tabManager.tabs.count ?? 0
  }

  func tabIndex(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Int? {
    states[worktreeID]?.tabManager.tabs.firstIndex(where: { $0.id == tabID })
  }

  func currentTabID(worktreeID: Worktree.ID) -> TerminalTabID? {
    states[worktreeID]?.tabManager.selectedTabId
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [WorktreeTerminalState] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append(state)
    }
    for state in removed {
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  func isRunScriptRunning(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isRunScriptRunning == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime.backgroundOpacity()
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }
}
