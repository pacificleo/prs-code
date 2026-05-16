import Foundation
import Testing

@testable import CherryLily

struct SurfaceLaunchCommandTests {
  private static let surface = SurfaceID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!)
  private static let paths = SessionPaths(
    root: URL(fileURLWithPath: "/Users/test/Library/Application Support/CherryLily/Sessions")
  )

  @Test func generatesTmuxNewSessionInvocation() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/Applications/CherryLily.app/Contents/MacOS/tmux",
      configPath: Self.paths.tmuxConfigFile.path,
      surface: Self.surface,
      cwd: "/Users/test/projects/repo"
    )

    #expect(command.contains("\"/Applications/CherryLily.app/Contents/MacOS/tmux\""))
    #expect(command.contains("-L cherrylily"))
    #expect(command.contains("new-session -A"))
    #expect(command.contains("-s \"\(Self.surface.tmuxSessionName)\""))
    #expect(command.contains("-c \"/Users/test/projects/repo\""))
  }

  // Regression test for a bug where the command started with `exec `, causing
  // Ghostty (which already wraps the string as `exec -l <cmd>`) to produce
  // `exec -l exec ...` — bash's exec builtin then tried to launch a program
  // literally named `exec` and failed with "exec: exec: not found".
  @Test func doesNotStartWithExecPrefix() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/path/to/tmux",
      configPath: "/path/to/tmux.conf",
      surface: Self.surface,
      cwd: "/cwd"
    )
    #expect(!command.hasPrefix("exec "))
    #expect(command.hasPrefix("\"/path/to/tmux\""))
  }

  @Test func includesConfigFilePath() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/path/to/tmux",
      configPath: "/path/to/tmux.conf",
      surface: Self.surface,
      cwd: "/cwd"
    )
    #expect(command.contains("-f \"/path/to/tmux.conf\""))
  }

  @Test func quotesPathsContainingSpaces() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/Applications/My App.app/Contents/MacOS/tmux",
      configPath: "/path with spaces/tmux.conf",
      surface: Self.surface,
      cwd: "/cwd with spaces"
    )
    #expect(command.contains("\"/Applications/My App.app/Contents/MacOS/tmux\""))
    #expect(command.contains("\"/path with spaces/tmux.conf\""))
    #expect(command.contains("\"/cwd with spaces\""))
  }

  @Test func escapesDoubleQuotesInPaths() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/tmp/tmux",
      configPath: "/tmp/conf",
      surface: Self.surface,
      cwd: "/tmp/weird\"path"
    )
    // The literal `"` in the cwd must be backslash-escaped inside the double-quoted argument
    #expect(command.contains("\"/tmp/weird\\\"path\""))
  }

  @Test func escapesDollarSignAndBacktickInPaths() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/tmp/tmux",
      configPath: "/tmp/conf",
      surface: Self.surface,
      cwd: "/tmp/$HOME`pwd`"
    )
    // Dollar signs and backticks must be escaped to prevent shell expansion inside double quotes
    #expect(command.contains("\\$HOME"))
    #expect(command.contains("\\`pwd\\`"))
  }

  @Test func escapesBackslashesInPaths() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/tmp/tmux",
      configPath: "/tmp/conf",
      surface: Self.surface,
      cwd: "/tmp/back\\slash"
    )
    // Backslash itself must be escaped — and it must be escaped FIRST so we don't double-escape later additions
    #expect(command.contains("\"/tmp/back\\\\slash\""))
  }

  @Test func usesSurfaceTmuxSessionName() {
    let command = SurfaceLaunchCommand.build(
      tmuxBinaryPath: "/t",
      configPath: "/c",
      surface: Self.surface,
      cwd: "/w"
    )
    // SurfaceID.tmuxSessionName is "cl_<lowercased-uuid>"
    #expect(command.contains("cl_12345678-1234-1234-1234-123456789abc"))
  }
}
