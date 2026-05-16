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

  @Test func buildWithReplayIncludesTmuxInvocationSkeleton() {
    let command = SurfaceLaunchCommand.buildWithReplay(
      tmuxBinaryPath: "/Applications/CherryLily.app/Contents/MacOS/tmux",
      configPath: Self.paths.tmuxConfigFile.path,
      surface: Self.surface,
      cwd: "/Users/test/projects/repo",
      replay: SurfaceLaunchCommand.ReplayOptions(
        scrollbackPath: "/Users/test/Library/.../sessions/file.bin",
        userShell: "/bin/zsh"
      )
    )

    // tmux invocation form preserved
    #expect(command.contains("\"/Applications/CherryLily.app/Contents/MacOS/tmux\""))
    #expect(command.contains("-L cherrylily"))
    #expect(command.contains("new-session -A"))
    #expect(command.contains("-s \"\(Self.surface.tmuxSessionName)\""))
    #expect(command.contains("-c \"/Users/test/projects/repo\""))
  }

  @Test func buildWithReplayIncludesCatAndExecWords() {
    let command = SurfaceLaunchCommand.buildWithReplay(
      tmuxBinaryPath: "/t",
      configPath: "/c",
      surface: Self.surface,
      cwd: "/cwd",
      replay: SurfaceLaunchCommand.ReplayOptions(
        scrollbackPath: "/scroll.bin",
        userShell: "/bin/zsh"
      )
    )
    // The words "cat" and "exec" must appear, regardless of quoting around them
    #expect(command.contains("cat "))
    #expect(command.contains("exec "))
    // Paths appear (the trailing portion is enough — surrounding quotes may have escape chars)
    #expect(command.contains("/scroll.bin"))
    #expect(command.contains("/bin/zsh"))
    // The trailing token must be quoted (so the whole cat-exec line is one bash argument)
    #expect(command.hasSuffix("\""))
  }

  @Test func buildWithReplayPreservesPathsWithSpaces() {
    let command = SurfaceLaunchCommand.buildWithReplay(
      tmuxBinaryPath: "/t",
      configPath: "/c",
      surface: Self.surface,
      cwd: "/cwd",
      replay: SurfaceLaunchCommand.ReplayOptions(
        scrollbackPath: "/path with spaces/scroll.bin",
        userShell: "/opt/My App/zsh"
      )
    )
    // Spaces preserved in both inner paths
    #expect(command.contains("/path with spaces/scroll.bin"))
    #expect(command.contains("/opt/My App/zsh"))
  }

  @Test func buildWithReplayProducesBashParseableOutput() throws {
    // Sanity: feed the output through bash and ask it to print the argv count.
    // If our quoting is wrong, bash will split mid-string and the argv count will be off.
    let command = SurfaceLaunchCommand.buildWithReplay(
      tmuxBinaryPath: "/t",
      configPath: "/c",
      surface: Self.surface,
      cwd: "/cwd",
      replay: SurfaceLaunchCommand.ReplayOptions(
        scrollbackPath: "/s.bin",
        userShell: "/bin/zsh"
      )
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "printf '%s\\n' \(command)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: data, encoding: .utf8) ?? ""
    let argvLines = stdout.split(separator: "\n", omittingEmptySubsequences: true)

    // Count elements: tmux + 11 args (-L, cherrylily, -f, /c, new-session, -A, -s, cl_X, -c, /cwd, sh-command) = 12
    #expect(argvLines.count == 12, "expected 12 argv elements; got \(argvLines.count): \(argvLines)")

    // The 12th element (index 11) must be the sh-command — single string containing cat & exec
    if argvLines.count >= 12 {
      let shCommand = String(argvLines[11])
      #expect(shCommand.contains("cat"))
      #expect(shCommand.contains("exec"))
      #expect(shCommand.contains("/s.bin"))
      #expect(shCommand.contains("/bin/zsh"))
    }
  }
}
