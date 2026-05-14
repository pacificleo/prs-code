import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import CherryLily

@MainActor
struct AppFeatureNavigationHistoryTests {
  private static let rootURL = URL(fileURLWithPath: "/tmp/repo")
  private static let worktreeA = Worktree(
    id: "/tmp/repo/wt-a",
    name: "wt-a",
    detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-a"),
    repositoryRootURL: rootURL
  )
  private static let worktreeB = Worktree(
    id: "/tmp/repo/wt-b",
    name: "wt-b",
    detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-b"),
    repositoryRootURL: rootURL
  )
  private static let repository = Repository(
    id: rootURL.path(percentEncoded: false),
    rootURL: rootURL,
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: [worktreeA, worktreeB])
  )

  private static func makeStore(
    initialState: AppFeature.State? = nil,
    currentTabID: @MainActor @Sendable @escaping (Worktree.ID) -> TerminalTabID? = { _ in nil },
    tabExists: @MainActor @Sendable @escaping (Worktree.ID, TerminalTabID) -> Bool = { _, _ in true },
    sentCommands: LockIsolated<[TerminalClient.Command]>? = nil
  ) -> TestStore<AppFeature.State, AppFeature.Action> {
    let state =
      initialState
      ?? AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: [repository]),
        settings: SettingsFeature.State()
      )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands?.withValue { $0.append(command) }
      }
      $0.terminalClient.currentTabID = currentTabID
      $0.terminalClient.tabExists = tabExists
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func selectedWorktreeChangedRecordsIntoHistory() async {
    let tabA = TerminalTabID()
    let store = Self.makeStore(currentTabID: { id in id == Self.worktreeA.id ? tabA : nil })

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(Self.worktreeA)))) {
      $0.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tabA))
    }
    await store.finish()
  }

  @Test(.dependencies) func tabFocusChangedForSelectedWorktreeRecordsEntry() async {
    var initialState = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    initialState.repositories.selection = .worktree(Self.worktreeA.id)
    let store = Self.makeStore(initialState: initialState)

    let tab1 = TerminalTabID()
    await store.send(.terminalEvent(.tabFocusChanged(worktreeID: Self.worktreeA.id, tabID: tab1))) {
      $0.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tab1))
    }
    await store.finish()
  }

  @Test(.dependencies) func tabFocusChangedForNonSelectedWorktreeIsIgnored() async {
    var initialState = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    initialState.repositories.selection = .worktree(Self.worktreeA.id)
    let store = Self.makeStore(initialState: initialState)

    let tab1 = TerminalTabID()
    // Tab change for B while A is selected should NOT record.
    await store.send(.terminalEvent(.tabFocusChanged(worktreeID: Self.worktreeB.id, tabID: tab1)))
    await store.finish()
    #expect(store.state.navigationHistory.current == nil)
  }

  @Test(.dependencies) func navigateBackEmitsSelectWorktreeAndFocusTab() async {
    let tabA = TerminalTabID()
    let tabB = TerminalTabID()
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    state.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tabA))
    state.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeB.id, tabID: tabB))
    state.repositories.selection = .worktree(Self.worktreeB.id)

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(initialState: state, sentCommands: sentCommands)

    await store.send(.navigateBack) {
      _ = $0.navigationHistory.goBack(isValid: { _ in true })
    }
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(
      sentCommands.value.contains(.focusTab(worktreeID: Self.worktreeA.id, tabID: tabA))
    )
  }

  @Test(.dependencies) func navigateBackIsNoOpWhenStackTooShort() async {
    let tabA = TerminalTabID()
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    state.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tabA))
    let store = Self.makeStore(initialState: state)

    await store.send(.navigateBack)
    await store.finish()
    #expect(store.state.navigationHistory.canGoBack == false)
  }

  @Test(.dependencies) func navigateForwardAfterBackRestoresEntry() async {
    let tabA = TerminalTabID()
    let tabB = TerminalTabID()
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    state.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tabA))
    state.navigationHistory.record(NavigationEntry(worktreeID: Self.worktreeB.id, tabID: tabB))
    _ = state.navigationHistory.goBack(isValid: { _ in true })
    state.repositories.selection = .worktree(Self.worktreeA.id)

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(initialState: state, sentCommands: sentCommands)

    await store.send(.navigateForward) {
      _ = $0.navigationHistory.goForward(isValid: { _ in true })
    }
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(
      sentCommands.value.contains(.focusTab(worktreeID: Self.worktreeB.id, tabID: tabB))
    )
  }

  @Test(.dependencies) func navigateBackSkipsRemovedWorktree() async {
    let tabA = TerminalTabID()
    let tabB = TerminalTabID()
    let removedID = "/tmp/repo/wt-removed"
    let entryA = NavigationEntry(worktreeID: Self.worktreeA.id, tabID: tabA)
    let entryRemoved = NavigationEntry(worktreeID: removedID, tabID: TerminalTabID())
    let entryB = NavigationEntry(worktreeID: Self.worktreeB.id, tabID: tabB)

    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [Self.repository]),
      settings: SettingsFeature.State()
    )
    state.navigationHistory.record(entryA)
    state.navigationHistory.record(entryRemoved)
    state.navigationHistory.record(entryB)
    state.repositories.selection = .worktree(Self.worktreeB.id)

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(initialState: state, sentCommands: sentCommands)

    await store.send(.navigateBack) {
      _ = $0.navigationHistory.goBack(isValid: { entry in
        entry.worktreeID == Self.worktreeA.id || entry.worktreeID == Self.worktreeB.id
      })
    }
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(
      sentCommands.value.contains(.focusTab(worktreeID: Self.worktreeA.id, tabID: tabA))
    )
  }
}
