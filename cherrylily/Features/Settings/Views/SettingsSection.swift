import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case sessions
  case developer
  case shortcuts
  case updates
  case appLauncher
  case github
  case repository(Repository.ID)
}
