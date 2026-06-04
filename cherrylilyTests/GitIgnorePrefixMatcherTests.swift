import Foundation
import Testing

@testable import CherryLily

struct GitIgnorePrefixMatcherTests {
  @Test func ignoresTopLevelDirectoryEntries() {
    let matcher = GitIgnorePrefixMatcher(lines: ["node_modules/", "build", "# comment", "", "  dist/  "])
    #expect(matcher.shouldIgnore(relativePath: "node_modules/react/index.js"))
    #expect(matcher.shouldIgnore(relativePath: "build/app.o"))
    #expect(matcher.shouldIgnore(relativePath: "dist/bundle.js"))
    #expect(!matcher.shouldIgnore(relativePath: "Sources/App.swift"))
  }

  @Test func alwaysIgnoresGitInternals() {
    let matcher = GitIgnorePrefixMatcher(lines: [])
    #expect(matcher.shouldIgnore(relativePath: ".git/HEAD"))
    #expect(matcher.shouldIgnore(relativePath: ".git/objects/ab/cd"))
  }

  @Test func skipsNegationsAndNestedPatternsConservatively() {
    // Negations and path-bearing patterns are not prefix-safe; ignore them (git remains source of truth).
    let matcher = GitIgnorePrefixMatcher(lines: ["!keep/", "src/generated/"])
    #expect(!matcher.shouldIgnore(relativePath: "keep/file"))
    #expect(!matcher.shouldIgnore(relativePath: "src/generated/x"))
  }
}
