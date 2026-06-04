import Foundation

/// Cheap, conservative top-level `.gitignore` prefilter. Only handles simple
/// top-level directory/file entries (the 90% noise case: `node_modules/`,
/// `build/`, …). Negations and nested/path patterns are skipped on purpose —
/// `git diff` remains the source of truth, so a missed ignore only costs one
/// cheap git run, never correctness.
struct GitIgnorePrefixMatcher {
  private let prefixes: [String]

  init(lines: [String]) {
    var prefixes: [String] = []
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") {
        continue
      }
      // Skip patterns that carry a path separator in the middle, globs, or anchors.
      let body = line.hasSuffix("/") ? String(line.dropLast()) : line
      if body.contains("/") || body.contains("*") || body.hasPrefix("/") {
        continue
      }
      if !body.isEmpty {
        prefixes.append(body + "/")
      }
    }
    self.prefixes = prefixes
  }

  /// Loads top-level `.gitignore` and `.git/info/exclude` for a worktree.
  init(worktreeURL: URL, gitDirectoryURL: URL, fileManager: FileManager = .default) {
    var lines: [String] = []
    let gitignore = worktreeURL.appending(path: ".gitignore")
    let exclude = gitDirectoryURL.appending(path: "info/exclude")
    for url in [gitignore, exclude] {
      if let content = try? String(contentsOf: url, encoding: .utf8) {
        lines.append(contentsOf: content.split(whereSeparator: \.isNewline).map(String.init))
      }
    }
    self.init(lines: lines)
  }

  func shouldIgnore(relativePath: String) -> Bool {
    if relativePath == ".git" || relativePath.hasPrefix(".git/") {
      return true
    }
    return prefixes.contains { relativePath.hasPrefix($0) }
  }
}
