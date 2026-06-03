import Foundation

/// Redirects `$HOME` to a throwaway directory for the test process.
///
/// Some tests spawn real shells — `TmuxClientCaptureTests` sends keystrokes into
/// a tmux pane, `WorktreeTerminalManagerTests` runs blocking scripts through a
/// Ghostty surface. Those shells are children of the test host, so they inherit
/// the developer's real `$HOME`, load the real `~/.zshrc`, and append every
/// fixture command (`echo ok`, `echo hello-capture`, the `CHERRYLILY_*` export
/// prefix, …) to the real `~/.zsh_history`.
///
/// Pointing `$HOME` at a temp dir makes those shells load no user `.zshrc`, so
/// `HISTFILE` defaults to `<tempHome>/.zsh_history` and the writes are discarded.
/// Setting `HISTFILE` directly would not survive a real `.zshrc` reassigning it;
/// moving `$HOME` sidesteps shell startup entirely.
///
/// This does NOT relocate DerivedData or SPM caches — those belong to the
/// `xcodebuild` parent process, which keeps the real `$HOME`. It also does not
/// affect `FileManager.homeDirectoryForCurrentUser` (which reads the account
/// record, not `$HOME`), so tests asserting against it are unaffected.
///
/// `activate` is a `static let`, so the redirect happens exactly once no matter
/// how many suites reference it. Reference it from the `init()` of any suite that
/// spawns a real shell.
enum TestHomeIsolation {
  static let activate: Void = {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "cl-test-home-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("HOME", dir.path, 1)
  }()
}
