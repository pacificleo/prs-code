import ComposableArchitecture
import Foundation
import AppKit
import UniformTypeIdentifiers

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
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
    var automaticallyArchiveMergedWorktrees: Bool
    var promptForWorktreeCreation: Bool
    var showShortcutHints: Bool
    var defaultWorktreeBaseDirectoryPath: String
    var disabledWorktreeActions: Set<String>
    var customWorktreeActions: [CustomWorktreeAction]
    var pinnedToolbarActions: [String]
    var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
    var selection: SettingsSection? = .general
    var repositorySettings: RepositorySettingsFeature.State?
    @Presents var alert: AlertState<Alert>?

    init(settings: GlobalSettings = .default) {
      let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
      appearanceMode = settings.appearanceMode
      defaultEditorID = normalizedDefaultEditorID
      confirmBeforeQuit = settings.confirmBeforeQuit
      confirmBeforeClosingTabs = settings.confirmBeforeClosingTabs
      restoreSessionsOnLaunch = settings.restoreSessionsOnLaunch
      sessionScrollbackLimit = settings.sessionScrollbackLimit
      hourlyAutosaveEnabled = settings.hourlyAutosaveEnabled
      updateChannel = settings.updateChannel
      updatesAutomaticallyCheckForUpdates = settings.updatesAutomaticallyCheckForUpdates
      updatesAutomaticallyDownloadUpdates = settings.updatesAutomaticallyDownloadUpdates
      inAppNotificationsEnabled = settings.inAppNotificationsEnabled
      notificationSoundEnabled = settings.notificationSoundEnabled
      systemNotificationsEnabled = settings.systemNotificationsEnabled
      moveNotifiedWorktreeToTop = settings.moveNotifiedWorktreeToTop
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      deleteBranchOnDeleteWorktree = settings.deleteBranchOnDeleteWorktree
      automaticallyArchiveMergedWorktrees = settings.automaticallyArchiveMergedWorktrees
      promptForWorktreeCreation = settings.promptForWorktreeCreation
      showShortcutHints = settings.showShortcutHints
      shortcutOverrides = settings.shortcutOverrides
      defaultWorktreeBaseDirectoryPath =
        CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath) ?? ""
      disabledWorktreeActions = settings.disabledWorktreeActions
      customWorktreeActions = settings.customWorktreeActions
      pinnedToolbarActions = settings.pinnedToolbarActions
    }

    var globalSettings: GlobalSettings {
      GlobalSettings(
        appearanceMode: appearanceMode,
        defaultEditorID: defaultEditorID,
        confirmBeforeQuit: confirmBeforeQuit,
        confirmBeforeClosingTabs: confirmBeforeClosingTabs,
        restoreSessionsOnLaunch: restoreSessionsOnLaunch,
        sessionScrollbackLimit: sessionScrollbackLimit,
        hourlyAutosaveEnabled: hourlyAutosaveEnabled,
        updateChannel: updateChannel,
        updatesAutomaticallyCheckForUpdates: updatesAutomaticallyCheckForUpdates,
        updatesAutomaticallyDownloadUpdates: updatesAutomaticallyDownloadUpdates,
        inAppNotificationsEnabled: inAppNotificationsEnabled,
        notificationSoundEnabled: notificationSoundEnabled,
        systemNotificationsEnabled: systemNotificationsEnabled,
        moveNotifiedWorktreeToTop: moveNotifiedWorktreeToTop,
        analyticsEnabled: analyticsEnabled,
        crashReportsEnabled: crashReportsEnabled,
        githubIntegrationEnabled: githubIntegrationEnabled,
        deleteBranchOnDeleteWorktree: deleteBranchOnDeleteWorktree,
        automaticallyArchiveMergedWorktrees: automaticallyArchiveMergedWorktrees,
        promptForWorktreeCreation: promptForWorktreeCreation,
        showShortcutHints: showShortcutHints,
        defaultWorktreeBaseDirectoryPath: CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(
          defaultWorktreeBaseDirectoryPath
        ),
        disabledWorktreeActions: disabledWorktreeActions,
        customWorktreeActions: customWorktreeActions,
        pinnedToolbarActions: pinnedToolbarActions,
        shortcutOverrides: shortcutOverrides
      )
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case addCustomApplicationButtonTapped
    case removeCustomAction(String)
    case setToolbarPin(id: String, pinned: Bool)
    case movePinnedToolbarAction(from: IndexSet, toOffset: Int)
    case showNotificationPermissionAlert(errorMessage: String?)
    case updateShortcut(id: AppShortcutID, override: AppShortcutOverride?)
    case toggleShortcutEnabled(id: AppShortcutID, enabled: Bool)
    case resetAllShortcuts
    case repositorySettings(RepositorySettingsFeature.Action)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  enum Alert: Equatable {
    case dismiss
    case openSystemNotificationSettings
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .send(.settingsLoaded(settingsFile.global))

      case .settingsLoaded(let settings):
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
        let normalizedWorktreeBaseDirPath =
          CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath)
        let normalizedSettings: GlobalSettings
        if normalizedDefaultEditorID == settings.defaultEditorID,
          normalizedWorktreeBaseDirPath == settings.defaultWorktreeBaseDirectoryPath
        {
          normalizedSettings = settings
        } else {
          var updatedSettings = settings
          updatedSettings.defaultEditorID = normalizedDefaultEditorID
          updatedSettings.defaultWorktreeBaseDirectoryPath = normalizedWorktreeBaseDirPath
          normalizedSettings = updatedSettings
          @Shared(.settingsFile) var settingsFile
          $settingsFile.withLock { $0.global = normalizedSettings }
        }
        state.appearanceMode = normalizedSettings.appearanceMode
        state.defaultEditorID = normalizedSettings.defaultEditorID
        state.confirmBeforeQuit = normalizedSettings.confirmBeforeQuit
        state.confirmBeforeClosingTabs = normalizedSettings.confirmBeforeClosingTabs
        state.restoreSessionsOnLaunch = normalizedSettings.restoreSessionsOnLaunch
        state.sessionScrollbackLimit = normalizedSettings.sessionScrollbackLimit
        state.hourlyAutosaveEnabled = normalizedSettings.hourlyAutosaveEnabled
        state.updateChannel = normalizedSettings.updateChannel
        state.updatesAutomaticallyCheckForUpdates = normalizedSettings.updatesAutomaticallyCheckForUpdates
        state.updatesAutomaticallyDownloadUpdates = normalizedSettings.updatesAutomaticallyDownloadUpdates
        state.inAppNotificationsEnabled = normalizedSettings.inAppNotificationsEnabled
        state.notificationSoundEnabled = normalizedSettings.notificationSoundEnabled
        state.systemNotificationsEnabled = normalizedSettings.systemNotificationsEnabled
        state.moveNotifiedWorktreeToTop = normalizedSettings.moveNotifiedWorktreeToTop
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.deleteBranchOnDeleteWorktree = normalizedSettings.deleteBranchOnDeleteWorktree
        state.automaticallyArchiveMergedWorktrees = normalizedSettings.automaticallyArchiveMergedWorktrees
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.showShortcutHints = normalizedSettings.showShortcutHints
        state.shortcutOverrides = normalizedSettings.shortcutOverrides
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.disabledWorktreeActions = normalizedSettings.disabledWorktreeActions
        state.customWorktreeActions = normalizedSettings.customWorktreeActions
        state.pinnedToolbarActions = normalizedSettings.pinnedToolbarActions
        state.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath =
          normalizedSettings.defaultWorktreeBaseDirectoryPath
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding:
        let defaultWorktreeBaseDirectoryPath = state.globalSettings.defaultWorktreeBaseDirectoryPath
        state.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath =
          defaultWorktreeBaseDirectoryPath
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        let defaultWorktreeBaseDirectoryPath = state.globalSettings.defaultWorktreeBaseDirectoryPath
        state.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath =
          defaultWorktreeBaseDirectoryPath
        return persist(state)

      case .showNotificationPermissionAlert(let errorMessage):
        let message: String
        if let errorMessage, !errorMessage.isEmpty {
          message =
            "CherryLily cannot send system notifications.\n\n"
            + "Error: \(errorMessage)"
        } else {
          message = "CherryLily cannot send system notifications while permission is denied."
        }
        state.alert = AlertState {
          TextState("Enable Notifications in System Settings")
        } actions: {
          ButtonState(action: .openSystemNotificationSettings) {
            TextState("Open System Settings")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState(message)
        }
        return .none

      case .updateShortcut(let id, let override):
        if let override {
          state.shortcutOverrides[id] = override
        } else {
          state.shortcutOverrides.removeValue(forKey: id)
        }
        return persist(state)

      case .toggleShortcutEnabled(let id, let enabled):
        if enabled {
          // Re-enable: if override exists with a real binding, just flip the flag.
          // If it was a disabled sentinel, remove the override entirely (restore default).
          if var existing = state.shortcutOverrides[id] {
            existing.isEnabled = true
            if existing.keyCode == 0, existing.modifiers.isEmpty {
              state.shortcutOverrides.removeValue(forKey: id)
            } else {
              state.shortcutOverrides[id] = existing
            }
          }
        } else {
          if var existing = state.shortcutOverrides[id] {
            existing.isEnabled = false
            state.shortcutOverrides[id] = existing
          } else {
            state.shortcutOverrides[id] = .disabled
          }
        }
        return persist(state)

      case .resetAllShortcuts:
        state.shortcutOverrides = [:]
        return persist(state)

      case .setSelection(let selection):
        state.selection = selection ?? .general
        return .none

      case .addCustomApplicationButtonTapped:
        return .run { send in
          let newApp: CustomWorktreeAction? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.application]
            panel.prompt = "Add Application"

            guard panel.runModal() == .OK, let url = panel.url else {
                return nil
            }

            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier ?? url.lastPathComponent

            let name: String
            if let displayName = FileManager.default.displayName(atPath: url.path) as String?, !displayName.isEmpty {
                name = displayName.replacingOccurrences(of: ".app", with: "")
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }

            let iconData: Data?
            if let image = NSWorkspace.shared.icon(forFile: url.path) as NSImage? {
                iconData = image.tiffRepresentation
            } else {
                iconData = nil
            }

            return CustomWorktreeAction(id: "custom.\(bundleID)", name: name, url: url, icon: iconData)
          }

          if let newApp {
            await MainActor.run {
                @Shared(.settingsFile) var settingsFile
                var currentSettings = settingsFile.global
                if !currentSettings.customWorktreeActions.contains(where: { $0.url == newApp.url }) {
                    currentSettings.customWorktreeActions.append(newApp)
                    $settingsFile.withLock { $0.global = currentSettings }
                    analyticsClient.capture("custom_app_added", ["app_name": newApp.name, "bundle_id": newApp.id])
                }
            }
            await send(.task)
          }
        }

      case .removeCustomAction(let id):
        state.customWorktreeActions.removeAll { $0.id == id }
        state.pinnedToolbarActions.removeAll { $0 == id }
        return persist(state)

      case let .setToolbarPin(id, pinned):
        if pinned {
          if !state.pinnedToolbarActions.contains(id) {
            state.pinnedToolbarActions.append(id)
          }
        } else {
          state.pinnedToolbarActions.removeAll { $0 == id }
        }
        return persist(state)

      case let .movePinnedToolbarAction(from, toOffset):
        state.pinnedToolbarActions = Self.moved(state.pinnedToolbarActions, fromOffsets: from, toOffset: toOffset)
        return persist(state)

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.openSystemNotificationSettings)):
        state.alert = nil
        return .run { _ in
          await systemNotificationClient.openSettings()
        }

      case .alert:
        return .none

      case .repositorySettings:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.repositorySettings, action: \.repositorySettings) {
      RepositorySettingsFeature()
    }
  }

  /// Reorders `array` matching SwiftUI's `move(fromOffsets:toOffset:)` semantics,
  /// without importing SwiftUI into this reducer.
  private static func moved<Element>(
    _ array: [Element],
    fromOffsets source: IndexSet,
    toOffset destination: Int
  ) -> [Element] {
    var result = array
    let moving = source.sorted().map { array[$0] }
    for index in source.sorted(by: >) {
      result.remove(at: index)
    }
    let adjustedDestination = destination - source.filter { $0 < destination }.count
    result.insert(contentsOf: moving, at: adjustedDestination)
    return result
  }

  private func persist(_ state: State) -> Effect<Action> {
    let settings = state.globalSettings
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    if settings.analyticsEnabled {
      analyticsClient.capture("settings_changed", nil)
    }
    return .send(.delegate(.settingsChanged(settings)))
  }
}
