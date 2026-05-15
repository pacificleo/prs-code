import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import CherryLily

@MainActor
struct AppFeatureTabCloseConfirmationTests {
  private static let rootURL = URL(fileURLWithPath: "/tmp/repo")
  private static let worktree = Worktree(
    id: "/tmp/repo/wt-a",
    name: "wt-a",
    detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-a"),
    repositoryRootURL: rootURL
  )
  private static let repository = Repository(
    id: rootURL.path(percentEncoded: false),
    rootURL: rootURL,
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: [worktree])
  )

  private static func makeStore(
    confirmEnabled: Bool,
    tabTitle: String? = "tab title",
    tabCount: Int = 3,
    tabIndex: Int? = 1,
    sentCommands: LockIsolated<[TerminalClient.Command]>? = nil
  ) -> TestStore<AppFeature.State, AppFeature.Action> {
    var settings = GlobalSettings.default
    settings.confirmBeforeClosingTabs = confirmEnabled
    let state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [repository]),
      settings: SettingsFeature.State(settings: settings)
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands?.withValue { $0.append(command) }
      }
      $0.terminalClient.tabTitle = { _, _ in tabTitle }
      $0.terminalClient.tabCount = { _ in tabCount }
      $0.terminalClient.tabIndex = { _, _ in tabIndex }
      $0.terminalClient.currentTabID = { _ in nil }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func requestCloseTabWithConfirmDisabledClosesImmediately() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: false, sentCommands: sentCommands)

    await store.send(.requestCloseTab(worktreeID: Self.worktree.id, tabID: tabID))
    await store.finish()

    #expect(store.state.alert == nil)
    #expect(sentCommands.value == [.closeTab(worktreeID: Self.worktree.id, tabID: tabID)])
  }

  @Test(.dependencies) func requestCloseTabWithConfirmEnabledShowsAlert() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: true, tabTitle: "branch 1", sentCommands: sentCommands)

    await store.send(.requestCloseTab(worktreeID: Self.worktree.id, tabID: tabID))
    await store.finish()

    #expect(store.state.alert != nil)
    #expect(sentCommands.value.isEmpty)
  }

  @Test(.dependencies) func confirmingCloseTabIssuesCloseCommand() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: true, sentCommands: sentCommands)

    await store.send(.requestCloseTab(worktreeID: Self.worktree.id, tabID: tabID))
    await store.send(.alert(.presented(.confirmCloseTab(worktreeID: Self.worktree.id, tabID: tabID)))) {
      $0.alert = nil
    }
    await store.finish()

    #expect(sentCommands.value == [.closeTab(worktreeID: Self.worktree.id, tabID: tabID)])
  }

  @Test(.dependencies) func dismissingCloseTabAlertSendsNoCommand() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: true, sentCommands: sentCommands)

    await store.send(.requestCloseTab(worktreeID: Self.worktree.id, tabID: tabID))
    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }
    await store.finish()

    #expect(sentCommands.value.isEmpty)
  }

  @Test(.dependencies) func tabCloseRequestedEventRoutesToRequestCloseTab() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: false, sentCommands: sentCommands)

    await store.send(.terminalEvent(.tabCloseRequested(worktreeID: Self.worktree.id, tabID: tabID)))
    await store.receive(\.requestCloseTab)
    await store.finish()

    #expect(sentCommands.value == [.closeTab(worktreeID: Self.worktree.id, tabID: tabID)])
  }

  @Test(.dependencies) func requestCloseOtherTabsConfirmEnabledShowsAlert() async {
    let keepingTabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: true, tabCount: 4, sentCommands: sentCommands)

    await store.send(
      .requestCloseOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)
    )
    await store.finish()

    #expect(store.state.alert != nil)
    #expect(sentCommands.value.isEmpty)
  }

  @Test(.dependencies) func requestCloseOtherTabsConfirmDisabledIssuesCommand() async {
    let keepingTabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: false, tabCount: 4, sentCommands: sentCommands)

    await store.send(
      .requestCloseOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)
    )
    await store.finish()

    #expect(
      sentCommands.value
        == [.closeOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)]
    )
  }

  @Test(.dependencies) func requestCloseOtherTabsZeroOthersIsNoOp() async {
    let keepingTabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    // Only one tab total → no others to close
    let store = Self.makeStore(confirmEnabled: true, tabCount: 1, sentCommands: sentCommands)

    await store.send(
      .requestCloseOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)
    )
    await store.finish()

    #expect(store.state.alert == nil)
    #expect(sentCommands.value.isEmpty)
  }

  @Test(.dependencies) func confirmingCloseOtherTabsIssuesCommand() async {
    let keepingTabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(confirmEnabled: true, tabCount: 3, sentCommands: sentCommands)

    await store.send(
      .requestCloseOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)
    )
    await store.send(
      .alert(.presented(.confirmCloseOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)))
    ) {
      $0.alert = nil
    }
    await store.finish()

    #expect(
      sentCommands.value
        == [.closeOtherTabs(worktreeID: Self.worktree.id, keepingTabID: keepingTabID)]
    )
  }

  @Test(.dependencies) func requestCloseTabsToRightZeroToRightIsNoOp() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    // Anchor at last index → 0 to the right
    let store = Self.makeStore(
      confirmEnabled: true,
      tabCount: 3,
      tabIndex: 2,
      sentCommands: sentCommands
    )

    await store.send(.requestCloseTabsToRight(worktreeID: Self.worktree.id, ofTabID: tabID))
    await store.finish()

    #expect(store.state.alert == nil)
    #expect(sentCommands.value.isEmpty)
  }

  @Test(.dependencies) func confirmingCloseTabsToRightIssuesCommand() async {
    let tabID = TerminalTabID()
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(
      confirmEnabled: true,
      tabCount: 4,
      tabIndex: 1,
      sentCommands: sentCommands
    )

    await store.send(.requestCloseTabsToRight(worktreeID: Self.worktree.id, ofTabID: tabID))
    await store.send(
      .alert(.presented(.confirmCloseTabsToRight(worktreeID: Self.worktree.id, ofTabID: tabID)))
    ) {
      $0.alert = nil
    }
    await store.finish()

    #expect(
      sentCommands.value
        == [.closeTabsToRight(worktreeID: Self.worktree.id, ofTabID: tabID)]
    )
  }
}
