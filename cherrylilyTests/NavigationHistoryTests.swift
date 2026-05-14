import Testing

@testable import CherryLily

@MainActor
struct NavigationHistoryTests {
  private let tabA = TerminalTabID()
  private let tabB = TerminalTabID()
  private let tabC = TerminalTabID()
  private let tabD = TerminalTabID()

  private var entryA: NavigationEntry { NavigationEntry(worktreeID: "wt-1", tabID: tabA) }
  private var entryB: NavigationEntry { NavigationEntry(worktreeID: "wt-1", tabID: tabB) }
  private var entryC: NavigationEntry { NavigationEntry(worktreeID: "wt-2", tabID: tabC) }
  private var entryD: NavigationEntry { NavigationEntry(worktreeID: "wt-2", tabID: tabD) }

  @Test func emptyHistoryHasNoNavigation() {
    let history = NavigationHistory()
    #expect(history.current == nil)
    #expect(history.canGoBack == false)
    #expect(history.canGoForward == false)
  }

  @Test func recordPushesEntry() {
    var history = NavigationHistory()
    history.record(entryA)
    #expect(history.current == entryA)
    #expect(history.canGoBack == false)
    #expect(history.canGoForward == false)
  }

  @Test func recordSecondEntryEnablesBack() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    #expect(history.current == entryB)
    #expect(history.canGoBack == true)
    #expect(history.canGoForward == false)
  }

  @Test func recordIsIdempotentForSameAsCurrent() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryB)
    history.record(entryB)
    #expect(history.current == entryB)
    #expect(history.canGoBack == true)
    // backStack should be [A, B], not [A, B, B, B]
  }

  @Test func goBackMovesCursor() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    let dest = history.goBack(isValid: { _ in true })
    #expect(dest == entryB)
    #expect(history.current == entryB)
    #expect(history.canGoForward == true)
  }

  @Test func goBackOnSingleEntryReturnsNil() {
    var history = NavigationHistory()
    history.record(entryA)
    let dest = history.goBack(isValid: { _ in true })
    #expect(dest == nil)
    #expect(history.current == entryA)
  }

  @Test func goBackOnEmptyReturnsNil() {
    var history = NavigationHistory()
    let dest = history.goBack(isValid: { _ in true })
    #expect(dest == nil)
  }

  @Test func goForwardAfterBackRestores() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    _ = history.goBack(isValid: { _ in true })
    let dest = history.goForward(isValid: { _ in true })
    #expect(dest == entryC)
    #expect(history.current == entryC)
    #expect(history.canGoForward == false)
  }

  @Test func goForwardWithEmptyForwardReturnsNil() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    let dest = history.goForward(isValid: { _ in true })
    #expect(dest == nil)
  }

  @Test func recordAfterBackClearsForward() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    _ = history.goBack(isValid: { _ in true })
    #expect(history.canGoForward == true)
    history.record(entryD)
    #expect(history.current == entryD)
    #expect(history.canGoForward == false)
  }

  @Test func recordAfterBackToCurrentDoesNotClearForward() {
    // Going back returns the destination as the new current. If a subsequent
    // selection event brings the same entry through record(), the forward stack
    // must not be cleared (idempotent record).
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    let dest = history.goBack(isValid: { _ in true })
    #expect(dest == entryB)
    history.record(entryB)  // simulate the event-driven re-record
    #expect(history.canGoForward == true)
    #expect(history.current == entryB)
  }

  @Test func goBackSkipsInvalidEntries() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    let invalid: Set<NavigationEntry> = [entryB]
    let dest = history.goBack(isValid: { !invalid.contains($0) })
    #expect(dest == entryA)
    #expect(history.current == entryA)
    // Invalid entries are dropped from backStack
  }

  @Test func goForwardSkipsInvalidEntries() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    history.record(entryC)
    history.record(entryD)
    _ = history.goBack(isValid: { _ in true })  // current = C, forward = [D]
    _ = history.goBack(isValid: { _ in true })  // current = B, forward = [D, C]
    let invalid: Set<NavigationEntry> = [entryC]
    let dest = history.goForward(isValid: { !invalid.contains($0) })
    #expect(dest == entryD)
    #expect(history.current == entryD)
  }

  @Test func goBackReturnsNilWhenAllPriorEntriesInvalid() {
    var history = NavigationHistory()
    history.record(entryA)
    history.record(entryB)
    let invalid: Set<NavigationEntry> = [entryA]
    let dest = history.goBack(isValid: { !invalid.contains($0) })
    #expect(dest == nil)
    #expect(history.current == entryB)  // current is preserved when no valid back exists
  }

  @Test func capDropsOldestEntries() {
    var history = NavigationHistory()
    let cap = history.cap
    for index in 0..<(cap + 10) {
      history.record(NavigationEntry(worktreeID: "wt-\(index)", tabID: TerminalTabID()))
    }
    #expect(history.backStack.count == cap)
    // After cap is enforced, we should still have the most recent entries
    let lastEntry = history.backStack.last
    #expect(lastEntry?.worktreeID == "wt-\(cap + 9)")
  }
}
