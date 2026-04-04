import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case codingAgents
  case sessions
  case shortcuts
  case updates
  case appLauncher
  case github
  case repository(Repository.ID)
}
