import Foundation

struct NavigationEntry: Equatable, Hashable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID?
}

struct NavigationHistory: Equatable {
  private(set) var backStack: [NavigationEntry] = []
  private(set) var forwardStack: [NavigationEntry] = []
  let cap: Int = 50

  var current: NavigationEntry? { backStack.last }
  var canGoBack: Bool { backStack.count > 1 }
  var canGoForward: Bool { !forwardStack.isEmpty }

  mutating func record(_ entry: NavigationEntry) {
    if backStack.last == entry { return }
    backStack.append(entry)
    forwardStack.removeAll()
    enforceCap()
  }

  mutating func goBack(isValid: (NavigationEntry) -> Bool) -> NavigationEntry? {
    guard backStack.count >= 2 else { return nil }
    let saved = backStack.removeLast()
    while let candidate = backStack.last {
      if isValid(candidate) {
        forwardStack.append(saved)
        return candidate
      }
      backStack.removeLast()
    }
    backStack.append(saved)
    return nil
  }

  mutating func goForward(isValid: (NavigationEntry) -> Bool) -> NavigationEntry? {
    while let next = forwardStack.popLast() {
      if isValid(next) {
        backStack.append(next)
        enforceCap()
        return next
      }
    }
    return nil
  }

  private mutating func enforceCap() {
    let total = backStack.count + forwardStack.count
    if total > cap {
      let drop = total - cap
      let removable = min(drop, max(0, backStack.count - 1))
      if removable > 0 {
        backStack.removeFirst(removable)
      }
    }
  }
}
