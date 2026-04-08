import ComposableArchitecture
import Foundation

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var currentTabID: @MainActor @Sendable (Worktree.ID) -> TerminalTabID?
  var tabExists: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Bool
  var surfaceExists: @MainActor @Sendable (Worktree.ID, TerminalTabID, UUID) -> Bool
  var tabTitle: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> String?
  var tabCount: @MainActor @Sendable (Worktree.ID) -> Int
  var tabIndex: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Int?

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool, id: UUID? = nil)
    case createTabWithInput(Worktree, input: String, runSetupScriptIfNew: Bool, id: UUID? = nil)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case stopRunScript(Worktree)
    case runBlockingScript(Worktree, kind: BlockingScriptKind, script: String)
    case closeFocusedTab(Worktree)
    case closeFocusedSurface(Worktree)
    case closeTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
    case closeOtherTabs(worktreeID: Worktree.ID, keepingTabID: TerminalTabID)
    case closeTabsToRight(worktreeID: Worktree.ID, ofTabID: TerminalTabID)
    case performBindingAction(Worktree, action: String)
    case startSearch(Worktree)
    case searchSelection(Worktree)
    case navigateSearchNext(Worktree)
    case navigateSearchPrevious(Worktree)
    case endSearch(Worktree)
    case selectTab(Worktree, tabID: TerminalTabID)
    case focusSurface(Worktree, tabID: TerminalTabID, surfaceID: UUID, input: String? = nil)
    case splitSurface(
      Worktree, tabID: TerminalTabID, surfaceID: UUID, direction: SplitDirection,
      input: String?, id: UUID? = nil)
    case destroyTab(Worktree, tabID: TerminalTabID)
    case destroySurface(Worktree, tabID: TerminalTabID, surfaceID: UUID)
    case prune(Set<Worktree.ID>)
    case setNotificationsEnabled(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case focusTab(worktreeID: Worktree.ID, tabID: TerminalTabID)
    case refreshTabBarVisibility
  }

  enum Event: Equatable {
    case notificationReceived(worktreeID: Worktree.ID, title: String, body: String)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID)
    case tabCloseRequested(worktreeID: Worktree.ID, tabID: TerminalTabID)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case tabFocusChanged(worktreeID: Worktree.ID, tabID: TerminalTabID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case blockingScriptCompleted(
      worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    case setupScriptConsumed(worktreeID: Worktree.ID)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    events: { fatalError("TerminalClient.events not configured") },
    currentTabID: { _ in nil },
    tabExists: { _, _ in false },
    surfaceExists: { _, _, _ in false },
    tabTitle: { _, _ in nil },
    tabCount: { _ in 0 },
    tabIndex: { _, _ in nil }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    currentTabID: unimplemented("TerminalClient.currentTabID"),
    tabExists: unimplemented("TerminalClient.tabExists", placeholder: true),
    surfaceExists: unimplemented("TerminalClient.surfaceExists", placeholder: true),
    tabTitle: unimplemented("TerminalClient.tabTitle"),
    tabCount: unimplemented("TerminalClient.tabCount"),
    tabIndex: unimplemented("TerminalClient.tabIndex")
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
