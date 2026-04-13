import ArgumentParser

@main
struct CherryLilyCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cherrylily",
    abstract: "Control CherryLily from the command line.",
    subcommands: [
      OpenCommand.self,
      WorktreeCommand.self,
      TabCommand.self,
      SurfaceCommand.self,
      RepoCommand.self,
      SettingsCommand.self,
      SocketCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
