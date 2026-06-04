import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import CherryLily

struct RepositorySettingsKeyTests {
  @Test func encodingOmitsNilWorktreeBaseRef() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("worktreeBaseRef"))
    #expect(!json.contains("worktreeBaseDirectoryPath"))
  }

  @Test(.dependencies) func loadCreatesDefaultAndPersists() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    let settings = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(settings == RepositorySettings.default)

    let saved: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(
      saved.repositories[rootURL.path(percentEncoded: false)] == RepositorySettings.default
    )
  }

  @Test(.dependencies) func saveOverwritesExistingSettings() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    var updated = RepositorySettings.default
    updated.runScript = "echo updated"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.repositories[rootURL.path(percentEncoded: false)] == updated)
  }

  @Test func decodeMissingDeleteScriptDefaultsToEmpty() throws {
    let data = Data(
      """
      {
        "setupScript": "echo setup",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.deleteScript.isEmpty)
  }

  @Test func decodeMissingArchiveScriptDefaultsToEmpty() throws {
    let data = Data(
      """
      {
        "setupScript": "echo setup",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.archiveScript.isEmpty)
  }

  @Test(.dependencies) func loadReturnsExistingGlobalEntry() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    let loaded = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == globalSettings)
  }

  @Test(.dependencies) func saveWritesToGlobalConfig() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)

    var updated = RepositorySettings.default
    updated.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      return settingsFile
    }

    #expect(globalSaved.repositories[repositoryID] == updated)
  }
}
