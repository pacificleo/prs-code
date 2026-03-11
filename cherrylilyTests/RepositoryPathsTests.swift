import Foundation
import Testing

@testable import CherryLily

struct RepositoryNameTests {
  @Test func usesParentDirectoryNameForBareRepositoryRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")

    #expect(Repository.name(for: root) == "repo-alpha")
  }

  @Test func preservesNormalRepositoryName() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")

    #expect(Repository.name(for: root) == "repo-alpha")
  }
}

struct CherryLilyPathsTests {
  @Test func repositoryDirectoryUsesRepoNameForNormalRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = CherryLilyPaths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "repo-alpha")
  }

  @Test func repositoryDirectoryUsesSanitizedPathForBareRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let directory = CherryLilyPaths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "tmp_work_repo-alpha_.bare")
  }

  @Test func repositoryDirectoryDoesNotCollideForDifferentBareRoots() {
    let firstRoot = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let secondRoot = URL(fileURLWithPath: "/tmp/work/repo-beta/.bare")

    let firstDirectory = CherryLilyPaths.repositoryDirectory(for: firstRoot)
    let secondDirectory = CherryLilyPaths.repositoryDirectory(for: secondRoot)

    #expect(firstDirectory != secondDirectory)
  }

  @Test func worktreeBaseDirectoryDefaultsToLegacyRepositoryDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = CherryLilyPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )

    #expect(directory == CherryLilyPaths.repositoryDirectory(for: root))
  }

  @Test func worktreeBaseDirectoryUsesGlobalParentDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = CherryLilyPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedDirectory = URL(filePath: "/tmp/worktrees/repo-alpha", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func worktreeBaseDirectoryRepositoryOverrideTakesPrecedence() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = CherryLilyPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: "/tmp/repo-alpha-worktrees"
    )
    let expectedDirectory = URL(filePath: "/tmp/repo-alpha-worktrees", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func exampleWorktreePathUsesResolvedBaseDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let path = CherryLilyPaths.exampleWorktreePath(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedPath = URL(filePath: "/tmp/worktrees/repo-alpha/swift-otter", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)

    #expect(path == expectedPath)
  }
}
