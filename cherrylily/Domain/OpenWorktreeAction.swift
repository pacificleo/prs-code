import AppKit
import ComposableArchitecture

struct OpenWorktreeAction: Identifiable, Equatable, Hashable, Sendable {
  enum MenuIcon: Equatable, Sendable {
    case app(Data)
    case symbol(String)
  }

  var id: String { title }
  var bundleIdentifier: String
  var title: String
  var settingsID: String

  // Use Data instead of NSImage for Sendable compliance, hydrate on demand
  var labelTitle: String {
    switch self {
    case .finder: return "Finder"
    case .editor: return "$EDITOR"
    default: return title
    }
  }

  @MainActor
  var menuIcon: MenuIcon? {
    switch self {
    case .editor:
      return .symbol("apple.terminal")
    default:
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
      else { return nil }
      if let imageData = NSWorkspace.shared.icon(forFile: appURL.path).tiffRepresentation {
          return .app(imageData)
      }
      return nil
    }
  }

  var isInstalled: Bool {
    switch self {
    case .finder, .editor:
      return true
    default:
      if bundleIdentifier == "custom" { return true }
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
  }

  static let alacritty = OpenWorktreeAction(bundleIdentifier: "org.alacritty", title: "Alacritty", settingsID: "alacritty")
  static let antigravity = OpenWorktreeAction(bundleIdentifier: "com.google.antigravity", title: "Antigravity", settingsID: "antigravity")
  static let editor = OpenWorktreeAction(bundleIdentifier: "", title: "$EDITOR", settingsID: "editor")
  static let finder = OpenWorktreeAction(bundleIdentifier: "com.apple.finder", title: "Open Finder", settingsID: "finder")
  static let cursor = OpenWorktreeAction(bundleIdentifier: "com.todesktop.230313mzl4w4u92", title: "Cursor", settingsID: "cursor")
  static let githubDesktop = OpenWorktreeAction(bundleIdentifier: "com.github.GitHubClient", title: "GitHub Desktop", settingsID: "github-desktop")
  static let fork = OpenWorktreeAction(bundleIdentifier: "com.DanPristupov.Fork", title: "Fork", settingsID: "fork")
  static let gitkraken = OpenWorktreeAction(bundleIdentifier: "com.axosoft.gitkraken", title: "GitKraken", settingsID: "gitkraken")
  static let gitup = OpenWorktreeAction(bundleIdentifier: "co.gitup.mac", title: "GitUp", settingsID: "gitup")
  static let ghostty = OpenWorktreeAction(bundleIdentifier: "com.mitchellh.ghostty", title: "Ghostty", settingsID: "ghostty")
  static let intellij = OpenWorktreeAction(bundleIdentifier: "com.jetbrains.intellij", title: "IntelliJ IDEA", settingsID: "intellij")
  static let kitty = OpenWorktreeAction(bundleIdentifier: "net.kovidgoyal.kitty", title: "Kitty", settingsID: "kitty")
  static let pycharm = OpenWorktreeAction(bundleIdentifier: "com.jetbrains.pycharm", title: "PyCharm", settingsID: "pycharm")
  static let rustrover = OpenWorktreeAction(bundleIdentifier: "com.jetbrains.rustrover", title: "RustRover", settingsID: "rustrover")
  static let smartgit = OpenWorktreeAction(bundleIdentifier: "com.syntevo.smartgit", title: "SmartGit", settingsID: "smartgit")
  static let sourcetree = OpenWorktreeAction(bundleIdentifier: "com.torusknot.SourceTreeNotMAS", title: "Sourcetree", settingsID: "sourcetree")
  static let sublimeMerge = OpenWorktreeAction(bundleIdentifier: "com.sublimemerge", title: "Sublime Merge", settingsID: "sublime-merge")
  static let terminal = OpenWorktreeAction(bundleIdentifier: "com.apple.Terminal", title: "Terminal", settingsID: "terminal")
  static let vscode = OpenWorktreeAction(bundleIdentifier: "com.microsoft.VSCode", title: "VS Code", settingsID: "vscode")
  static let vscodeInsiders = OpenWorktreeAction(bundleIdentifier: "com.microsoft.VSCodeInsiders", title: "VS Code Insiders", settingsID: "vscode-insiders")
  static let warp = OpenWorktreeAction(bundleIdentifier: "dev.warp.Warp-Stable", title: "Warp", settingsID: "warp")
  static let webstorm = OpenWorktreeAction(bundleIdentifier: "com.jetbrains.WebStorm", title: "WebStorm", settingsID: "webstorm")
  static let wezterm = OpenWorktreeAction(bundleIdentifier: "com.github.wez.wezterm", title: "WezTerm", settingsID: "wezterm")
  static let windsurf = OpenWorktreeAction(bundleIdentifier: "com.exafunction.windsurf", title: "Windsurf", settingsID: "windsurf")
  static let xcode = OpenWorktreeAction(bundleIdentifier: "com.apple.dt.Xcode", title: "Xcode", settingsID: "xcode")
  static let zed = OpenWorktreeAction(bundleIdentifier: "dev.zed.Zed", title: "Zed", settingsID: "zed")

  static let allPredefinedCases: [OpenWorktreeAction] = [
    .alacritty, .antigravity, .editor, .finder, .cursor, .githubDesktop, .fork, .gitkraken,
    .gitup, .ghostty, .intellij, .kitty, .pycharm, .rustrover, .smartgit, .sourcetree,
    .sublimeMerge, .terminal, .vscode, .vscodeInsiders, .warp, .webstorm, .wezterm,
    .windsurf, .xcode, .zed
  ]

  static let automaticSettingsID = "auto"

  static let editorPriority: [OpenWorktreeAction] = [
    .cursor, .zed, .vscode, .windsurf, .vscodeInsiders, .intellij, .webstorm, .pycharm,
    .rustrover, .antigravity
  ]

  static let terminalPriority: [OpenWorktreeAction] = [
    .ghostty, .wezterm, .alacritty, .kitty, .warp, .terminal
  ]

  static let gitClientPriority: [OpenWorktreeAction] = [
    .githubDesktop, .sourcetree, .fork, .gitkraken, .sublimeMerge, .smartgit, .gitup
  ]

  static let defaultPriority: [OpenWorktreeAction] =
    editorPriority + [.xcode, .finder] + terminalPriority + gitClientPriority

  static let menuOrder: [OpenWorktreeAction] =
    editorPriority + [.xcode] + [.finder] + terminalPriority + gitClientPriority + [.editor]

  static func normalizedDefaultEditorID(_ settingsID: String?) -> String {
    guard let settingsID, settingsID != automaticSettingsID else {
      return automaticSettingsID
    }
    // We check against all known builtins
    guard let action = allPredefinedCases.first(where: { $0.settingsID == settingsID }) else {
      // Must be a custom app ID
      return settingsID
    }
    if action.isInstalled {
        return settingsID
    }
    return automaticSettingsID
  }

  static func fromSettingsID(
    _ settingsID: String?,
    defaultEditorID: String?,
    globalSettings: GlobalSettings
  ) -> OpenWorktreeAction {
    let combinedActions = availableCases(settings: globalSettings)

    if let settingsID, settingsID != automaticSettingsID,
      let action = combinedActions.first(where: { $0.settingsID == settingsID })
    {
      return action
    }
    let normalizedDefaultEditorID = normalizedDefaultEditorID(defaultEditorID)
    if normalizedDefaultEditorID != automaticSettingsID,
      let action = combinedActions.first(where: { $0.settingsID == normalizedDefaultEditorID })
    {
      return action
    }
    return preferredDefault(settings: globalSettings)
  }

  static func availableCases(settings: GlobalSettings) -> [OpenWorktreeAction] {
    let builtIns = menuOrder.filter { $0.isInstalled && !settings.disabledWorktreeActions.contains($0.settingsID) }
    let custom = settings.customWorktreeActions.map { customAction in
        OpenWorktreeAction(
            bundleIdentifier: "custom", // Marker for custom action handling in perform
            title: customAction.name,
            settingsID: customAction.id
        )
    }
    return builtIns + custom
  }

  static func availableSelection(_ selection: OpenWorktreeAction, settings: GlobalSettings) -> OpenWorktreeAction {
    selection.isInstalled ? selection : preferredDefault(settings: settings)
  }

  static func preferredDefault(settings: GlobalSettings) -> OpenWorktreeAction {
    let combined = availableCases(settings: settings)
    return combined.first ?? .finder
  }

  func perform(with worktree: Worktree, onError: @escaping @MainActor @Sendable (OpenActionError) -> Void) {
    let actionTitle = title
    if self == .editor { return }
    if self == .finder {
      NSWorkspace.shared.activateFileViewerSelecting([worktree.workingDirectory])
      return
    }

    // Apps that require CLI arguments instead of Apple Events to open directories.
    if [.intellij, .webstorm, .pycharm, .rustrover].contains(self) {
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        onError(OpenActionError(title: "\(title) not found", message: "Install \(title) to open this worktree."))
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      configuration.arguments = [worktree.workingDirectory.path]
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        guard let error else { return }
        Task { @MainActor in onError(OpenActionError(title: "Unable to open in \(actionTitle)", message: error.localizedDescription)) }
      }
      return
    }

    // Standard Apple Events URL opening
    let appURL: URL
    if bundleIdentifier == "custom" { // Marked custom applications
        @Shared(.settingsFile) var settingsFile
        guard let customApp = settingsFile.global.customWorktreeActions.first(where: { $0.id == settingsID }) else {
            onError(OpenActionError(title: "\(title) not found", message: "Custom application not configured properly."))
            return
        }
        appURL = customApp.url
    } else {
        guard let resolvedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            onError(OpenActionError(title: "\(title) not found", message: "Install \(title) to open this worktree."))
            return
        }
        appURL = resolvedURL
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([worktree.workingDirectory], withApplicationAt: appURL, configuration: configuration) { _, error in
      guard let error else { return }
      Task { @MainActor in onError(OpenActionError(title: "Unable to open in \(actionTitle)", message: error.localizedDescription)) }
    }
  }
}
