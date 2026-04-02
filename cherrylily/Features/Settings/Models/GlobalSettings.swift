import Foundation

nonisolated enum AutoDeletePeriod: Int, Codable, CaseIterable, Comparable, Sendable {
  #if DEBUG
    case immediately = 0
  #endif
  case oneDay = 1
  case threeDays = 3
  case sevenDays = 7
  case fourteenDays = 14
  case thirtyDays = 30

  var label: String {
    switch self {
    #if DEBUG
      case .immediately: "Immediately (debug)"
    #endif
    case .oneDay: "After 1 day"
    case .threeDays: "After 3 days"
    case .sevenDays: "After 7 days"
    case .fourteenDays: "After 14 days"
    case .thirtyDays: "After 30 days"
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

nonisolated struct CustomWorktreeAction: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var url: URL
  var icon: Data?
}

nonisolated struct GlobalSettings: Codable, Equatable, Sendable {
  var appearanceMode: AppearanceMode
  var defaultEditorID: String
  var confirmBeforeQuit: Bool
  var confirmBeforeClosingTabs: Bool
  var restoreSessionsOnLaunch: Bool
  var sessionScrollbackLimit: Int?
  var hourlyAutosaveEnabled: Bool
  var updateChannel: UpdateChannel
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var inAppNotificationsEnabled: Bool
  var notificationSoundEnabled: Bool
  var systemNotificationsEnabled: Bool
  var moveNotifiedWorktreeToTop: Bool
  var analyticsEnabled: Bool
  var crashReportsEnabled: Bool
  var githubIntegrationEnabled: Bool
  var deleteBranchOnDeleteWorktree: Bool
  var mergedWorktreeAction: MergedWorktreeAction?
  var promptForWorktreeCreation: Bool
  var showShortcutHints: Bool
  var fetchOriginBeforeWorktreeCreation: Bool
  var defaultWorktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool
  var copyUntrackedOnWorktreeCreate: Bool
  var pullRequestMergeStrategy: PullRequestMergeStrategy
  var terminalThemeSyncEnabled: Bool
  var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
  var shortcutOverrides: [AppShortcutID: AppShortcutOverride]

  var disabledWorktreeActions: Set<String>
  var customWorktreeActions: [CustomWorktreeAction]
  var pinnedToolbarActions: [String]

  static let `default` = GlobalSettings(
    appearanceMode: .dark,
    defaultEditorID: "auto",
    confirmBeforeQuit: true,
    confirmBeforeClosingTabs: true,
    restoreSessionsOnLaunch: true,
    sessionScrollbackLimit: 50_000,
    hourlyAutosaveEnabled: false,
    updateChannel: .stable,
    updatesAutomaticallyCheckForUpdates: true,
    updatesAutomaticallyDownloadUpdates: false,
    inAppNotificationsEnabled: true,
    notificationSoundEnabled: true,
    systemNotificationsEnabled: false,
    moveNotifiedWorktreeToTop: true,
    analyticsEnabled: true,
    crashReportsEnabled: true,
    githubIntegrationEnabled: true,
    deleteBranchOnDeleteWorktree: true,
    mergedWorktreeAction: nil,
    promptForWorktreeCreation: true,
    showShortcutHints: false,
    fetchOriginBeforeWorktreeCreation: true,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge,
    terminalThemeSyncEnabled: false,
    defaultWorktreeBaseDirectoryPath: nil,
    disabledWorktreeActions: [],
    customWorktreeActions: [],
    pinnedToolbarActions: ["finder", "editor"],
    autoDeleteArchivedWorktreesAfterDays: nil,
    shortcutOverrides: [:]
  )

  init(
    appearanceMode: AppearanceMode,
    defaultEditorID: String,
    confirmBeforeQuit: Bool,
    confirmBeforeClosingTabs: Bool = true,
    restoreSessionsOnLaunch: Bool = true,
    sessionScrollbackLimit: Int? = 50_000,
    hourlyAutosaveEnabled: Bool = false,
    updateChannel: UpdateChannel,
    updatesAutomaticallyCheckForUpdates: Bool,
    updatesAutomaticallyDownloadUpdates: Bool,
    inAppNotificationsEnabled: Bool,
    notificationSoundEnabled: Bool,
    systemNotificationsEnabled: Bool = false,
    moveNotifiedWorktreeToTop: Bool,
    analyticsEnabled: Bool,
    crashReportsEnabled: Bool,
    githubIntegrationEnabled: Bool,
    deleteBranchOnDeleteWorktree: Bool,
    mergedWorktreeAction: MergedWorktreeAction? = nil,
    promptForWorktreeCreation: Bool,
    showShortcutHints: Bool = false,
    fetchOriginBeforeWorktreeCreation: Bool = true,
    copyIgnoredOnWorktreeCreate: Bool = false,
    copyUntrackedOnWorktreeCreate: Bool = false,
    pullRequestMergeStrategy: PullRequestMergeStrategy = .merge,
    terminalThemeSyncEnabled: Bool = false,
    defaultWorktreeBaseDirectoryPath: String? = nil,
    disabledWorktreeActions: Set<String> = [],
    customWorktreeActions: [CustomWorktreeAction] = [],
    pinnedToolbarActions: [String] = [],
    autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod? = nil,
    shortcutOverrides: [AppShortcutID: AppShortcutOverride] = [:]
  ) {
    self.appearanceMode = appearanceMode
    self.defaultEditorID = defaultEditorID
    self.confirmBeforeQuit = confirmBeforeQuit
    self.confirmBeforeClosingTabs = confirmBeforeClosingTabs
    self.restoreSessionsOnLaunch = restoreSessionsOnLaunch
    self.sessionScrollbackLimit = sessionScrollbackLimit
    self.hourlyAutosaveEnabled = hourlyAutosaveEnabled
    self.updateChannel = updateChannel
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.inAppNotificationsEnabled = inAppNotificationsEnabled
    self.notificationSoundEnabled = notificationSoundEnabled
    self.systemNotificationsEnabled = systemNotificationsEnabled
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.analyticsEnabled = analyticsEnabled
    self.crashReportsEnabled = crashReportsEnabled
    self.githubIntegrationEnabled = githubIntegrationEnabled
    self.deleteBranchOnDeleteWorktree = deleteBranchOnDeleteWorktree
    self.mergedWorktreeAction = mergedWorktreeAction
    self.promptForWorktreeCreation = promptForWorktreeCreation
    self.showShortcutHints = showShortcutHints
    self.fetchOriginBeforeWorktreeCreation = fetchOriginBeforeWorktreeCreation
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.terminalThemeSyncEnabled = terminalThemeSyncEnabled
    self.defaultWorktreeBaseDirectoryPath = defaultWorktreeBaseDirectoryPath
    self.disabledWorktreeActions = disabledWorktreeActions
    self.customWorktreeActions = customWorktreeActions
    self.pinnedToolbarActions = pinnedToolbarActions
    self.autoDeleteArchivedWorktreesAfterDays = autoDeleteArchivedWorktreesAfterDays
    self.shortcutOverrides = shortcutOverrides
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appearanceMode = try container.decode(AppearanceMode.self, forKey: .appearanceMode)
    defaultEditorID =
      try container.decodeIfPresent(String.self, forKey: .defaultEditorID)
      ?? Self.default.defaultEditorID
    confirmBeforeQuit =
      try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit)
      ?? Self.default.confirmBeforeQuit
    confirmBeforeClosingTabs =
      try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeClosingTabs)
      ?? Self.default.confirmBeforeClosingTabs
    restoreSessionsOnLaunch =
      try container.decodeIfPresent(Bool.self, forKey: .restoreSessionsOnLaunch)
      ?? Self.default.restoreSessionsOnLaunch
    if let raw = try container.decodeIfPresent(Int.self, forKey: .sessionScrollbackLimit) {
      sessionScrollbackLimit = raw
    } else {
      sessionScrollbackLimit = Self.default.sessionScrollbackLimit
    }
    hourlyAutosaveEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .hourlyAutosaveEnabled)
      ?? Self.default.hourlyAutosaveEnabled
    updateChannel =
      try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel)
      ?? Self.default.updateChannel
    updatesAutomaticallyCheckForUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates)
    updatesAutomaticallyDownloadUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates)
    inAppNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .inAppNotificationsEnabled)
      ?? Self.default.inAppNotificationsEnabled
    notificationSoundEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled)
      ?? Self.default.notificationSoundEnabled
    systemNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled)
      ?? Self.default.systemNotificationsEnabled
    moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop)
      ?? Self.default.moveNotifiedWorktreeToTop
    analyticsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled)
      ?? Self.default.analyticsEnabled
    crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled)
      ?? Self.default.crashReportsEnabled
    githubIntegrationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .githubIntegrationEnabled)
      ?? Self.default.githubIntegrationEnabled
    deleteBranchOnDeleteWorktree =
      try container.decodeIfPresent(Bool.self, forKey: .deleteBranchOnDeleteWorktree)
      ?? Self.default.deleteBranchOnDeleteWorktree
    // `try?` intentionally swallows decoding errors (e.g. unrecognized raw values
    // from a future app version) and falls through to the legacy migration path,
    // which defaults to `nil`. Silently resetting the preference is acceptable
    // because `nil` (do nothing) is the safest default.
    if let action = try? container.decodeIfPresent(MergedWorktreeAction.self, forKey: .mergedWorktreeAction) {
      mergedWorktreeAction = action
    } else {
      // Legacy migration.
      struct LegacyCodingKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
      }
      let legacy = try decoder.container(keyedBy: LegacyCodingKey.self)
      if let legacyBool = try legacy.decodeIfPresent(
        Bool.self,
        forKey: LegacyCodingKey(stringValue: "automaticallyArchiveMergedWorktrees")!
      ) {
        mergedWorktreeAction = legacyBool ? .archive : Self.default.mergedWorktreeAction
      } else {
        mergedWorktreeAction = Self.default.mergedWorktreeAction
      }
    }
    promptForWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .promptForWorktreeCreation)
      ?? Self.default.promptForWorktreeCreation
    showShortcutHints =
      try container.decodeIfPresent(Bool.self, forKey: .showShortcutHints)
      ?? Self.default.showShortcutHints
    fetchOriginBeforeWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .fetchOriginBeforeWorktreeCreation)
      ?? Self.default.fetchOriginBeforeWorktreeCreation
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
      ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
      ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(PullRequestMergeStrategy.self, forKey: .pullRequestMergeStrategy)
      ?? Self.default.pullRequestMergeStrategy
    terminalThemeSyncEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .terminalThemeSyncEnabled)
      ?? Self.default.terminalThemeSyncEnabled
    defaultWorktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .defaultWorktreeBaseDirectoryPath)
      ?? Self.default.defaultWorktreeBaseDirectoryPath
    disabledWorktreeActions =
      try container.decodeIfPresent(Set<String>.self, forKey: .disabledWorktreeActions)
      ?? Self.default.disabledWorktreeActions
    customWorktreeActions =
      try container.decodeIfPresent([CustomWorktreeAction].self, forKey: .customWorktreeActions)
      ?? Self.default.customWorktreeActions
    pinnedToolbarActions =
      try container.decodeIfPresent([String].self, forKey: .pinnedToolbarActions)
      ?? OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: defaultEditorID)
    
    // Reject unrecognized values from corrupted or hand-edited settings files.
    autoDeleteArchivedWorktreesAfterDays =
      (try container.decodeIfPresent(Int.self, forKey: .autoDeleteArchivedWorktreesAfterDays))
      .flatMap(AutoDeletePeriod.init(rawValue:))
      ?? Self.default.autoDeleteArchivedWorktreesAfterDays
    shortcutOverrides =
      try container.decodeIfPresent([AppShortcutID: AppShortcutOverride].self, forKey: .shortcutOverrides)
      ?? Self.default.shortcutOverrides
  }
}
