import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import cherrylily

struct RepositoryPersistenceClientTests {
  @Test(.dependencies) func savesAndLoadsRootsAndPins() async throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
      }
    }

    let client = RepositoryPersistenceClient.liveValue
    let result = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.saveRoots([
        "/tmp/repo-a",
        "/tmp/repo-a",
        "/tmp/repo-b/../repo-b",
      ])
      await client.savePinnedWorktreeIDs([
        "/tmp/repo-a/wt-1",
        "/tmp/repo-a/wt-1",
      ])
      let roots = await client.loadRoots()
      let pinned = await client.loadPinnedWorktreeIDs()
      return (roots: roots, pinned: pinned)
    }

    #expect(result.roots == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(result.pinned == ["/tmp/repo-a/wt-1"])

    let finalSettings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(finalSettings.global.appearanceMode == .dark)
  }
}
