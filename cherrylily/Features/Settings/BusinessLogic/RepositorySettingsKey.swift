import Foundation
import Sharing

nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct RepositorySettingsKey: SharedKey {
  let repositoryID: String
  let rootURL: URL

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    repositoryID = self.rootURL.path(percentEncoded: false)
  }

  var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let settings = $settingsFile.withLock { settings in
      if let existing = settings.repositories[repositoryID] {
        return existing
      }
      let defaults = context.initialValue ?? .default
      settings.repositories[repositoryID] = defaults
      return defaults
    }
    continuation.resume(returning: settings)
  }

  func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    $settingsFile.withLock {
      $0.repositories[repositoryID] = value
    }
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  static func repositorySettings(_ rootURL: URL) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL), default: .default]
  }
}
