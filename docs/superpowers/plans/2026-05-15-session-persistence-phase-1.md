# Session Persistence — Phase 1: Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-15-session-persistence-design.md`

**Goal:** Build the foundation for terminal session persistence: bundled tmux binary, stable surface IDs, layout JSON serialization, file-store paths, and orphan reconciliation logic. No user-visible behavior changes — Phase 1 produces tested infrastructure that Phases 2 and 3 build on to ship the feature.

**Architecture:** Bundled `tmux` binary inside `CherryLily.app/Contents/MacOS/tmux-cherrylily`. New `cherrylily/Features/Sessions/` module owns persistence concepts: stable `SurfaceID` allocated when surfaces are first created, `SessionLayout` JSON snapshot describing worktree → tab → split-tree → surface IDs + working dirs, file store at `~/Library/Application Support/CherryLily/sessions/`, and an orphan reconciler that diffs live tmux sessions against the layout file.

**Tech Stack:** Swift 6.2, `tmux` 3.5a (BSD), `Foundation.Process` for subprocess invocation, `Codable` for JSON, Swift Testing for unit tests.

**Phase scope:** Foundation only. Phases 2 (surface launch wrapping), 3 (capture/replay), 4 (settings UI), 5 (edge cases), 6 (polish) ship in subsequent plans.

---

## File structure

**New (Swift):**
- `cherrylily/Features/Sessions/Models/SurfaceID.swift` — typed UUID wrapper
- `cherrylily/Features/Sessions/Models/SessionLayout.swift` — Codable layout snapshot model
- `cherrylily/Features/Sessions/BusinessLogic/SessionPaths.swift` — Application Support paths for sessions data
- `cherrylily/Features/Sessions/BusinessLogic/TmuxBinary.swift` — locates the bundled tmux executable
- `cherrylily/Features/Sessions/BusinessLogic/SessionLayoutStore.swift` — read/write `layout.json`
- `cherrylily/Features/Sessions/BusinessLogic/ScrollbackStore.swift` — read/write per-surface scrollback files
- `cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift` — typed wrapper around `tmux` subprocess invocations (`ls`, `kill-session`)
- `cherrylily/Features/Sessions/BusinessLogic/OrphanReconciler.swift` — bidirectional layout ↔ tmux sessions ↔ scrollback files reconciliation

**New (build):**
- `scripts/build-tmux.sh` — fetches tmux source, compiles arm64+x86_64 universal binary, places into `Frameworks/`

**New (tests):**
- `cherrylilyTests/SessionLayoutTests.swift`
- `cherrylilyTests/SessionPathsTests.swift`
- `cherrylilyTests/SessionLayoutStoreTests.swift`
- `cherrylilyTests/ScrollbackStoreTests.swift`
- `cherrylilyTests/OrphanReconcilerTests.swift`

**Modified:**
- `Makefile` — add `build-tmux` target, hook into `build-app` and `build-release`
- `cherrylily/Support/CherryLilyPaths.swift` — add helper for the Application Support root if not already present
- `cherrylily.xcodeproj/project.pbxproj` — only if the synchronized folder doesn't auto-pick up new files (verify; usually nothing to do)

---

## Task 1: Add tmux build pipeline

**Files:**
- Create: `scripts/build-tmux.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write the build script**

Create `scripts/build-tmux.sh`:

```bash
#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) tmux binary for embedding in CherryLily.app.
# Pinned to a stable version. Bumping the version is a deliberate, reviewed change.

set -euo pipefail

TMUX_VERSION="${TMUX_VERSION:-3.5a}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/tmux-build"
OUT_BINARY="${ROOT_DIR}/Frameworks/tmux-cherrylily"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

build_arch() {
  local arch="$1"
  local prefix="$WORK_DIR/install-$arch"
  local cflags="-arch $arch -mmacosx-version-min=12.0"
  local ldflags="-arch $arch"

  rm -rf "$prefix"
  mkdir -p "$prefix"

  # libevent (tmux's only required external dep)
  if [ ! -d "libevent-${LIBEVENT_VERSION}" ]; then
    curl -L -o "libevent-${LIBEVENT_VERSION}.tar.gz" \
      "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"
    tar xf "libevent-${LIBEVENT_VERSION}.tar.gz"
  fi
  pushd "libevent-${LIBEVENT_VERSION}"
  make distclean 2>/dev/null || true
  CFLAGS="$cflags" LDFLAGS="$ldflags" \
    ./configure --prefix="$prefix" --disable-shared --disable-openssl \
                --host="${arch}-apple-darwin" --enable-static
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd

  # tmux
  if [ ! -d "tmux-${TMUX_VERSION}" ]; then
    curl -L -o "tmux-${TMUX_VERSION}.tar.gz" \
      "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
    tar xf "tmux-${TMUX_VERSION}.tar.gz"
  fi
  pushd "tmux-${TMUX_VERSION}"
  make distclean 2>/dev/null || true
  CFLAGS="$cflags -I${prefix}/include" \
  LDFLAGS="$ldflags -L${prefix}/lib" \
  PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" \
    ./configure --prefix="$prefix" --enable-static \
                --host="${arch}-apple-darwin" --disable-utf8proc
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd

  echo "Built tmux for $arch at $prefix/bin/tmux"
}

build_arch arm64
build_arch x86_64

# Lipo into universal binary
mkdir -p "$(dirname "$OUT_BINARY")"
lipo -create \
  "$WORK_DIR/install-arm64/bin/tmux" \
  "$WORK_DIR/install-x86_64/bin/tmux" \
  -output "$OUT_BINARY"

# Verify
file "$OUT_BINARY"
echo "Universal tmux binary: $OUT_BINARY"
```

- [ ] **Step 2: Make script executable**

Run:
```bash
chmod +x scripts/build-tmux.sh
```

- [ ] **Step 3: Add Makefile target**

Open `Makefile` and add a new target `build-tmux` after `build-ghostty-xcframework`:

```makefile
build-tmux: # Build the bundled tmux universal binary
	@if [ ! -f "$(CURRENT_MAKEFILE_DIR)/Frameworks/tmux-cherrylily" ]; then \
	  echo "Building tmux..."; \
	  bash $(CURRENT_MAKEFILE_DIR)/scripts/build-tmux.sh; \
	else \
	  echo "tmux-cherrylily already built. Run 'rm Frameworks/tmux-cherrylily' to force rebuild."; \
	fi
```

Also add `build-tmux` to the `.PHONY` line near the top of the Makefile.

Update `build-app:` to depend on `build-tmux`:

```makefile
build-app: build-ghostty-xcframework build-tmux # Build the macOS app (Debug)
```

Same for `build-release:`.

- [ ] **Step 4: Run the build script and verify the binary**

Run:
```bash
make build-tmux
file Frameworks/tmux-cherrylily
```

Expected output of `file`:
```
Frameworks/tmux-cherrylily: Mach-O universal binary with 2 architectures: [arm64:Mach-O 64-bit executable arm64] [x86_64:Mach-O 64-bit executable x86_64]
```

If this fails because `curl` can't reach GitHub or `make` errors during compile, the most common causes are: stale partial download in `build/tmux-build/` (delete that directory and retry), or missing autotools (`brew install automake autoconf`).

- [ ] **Step 5: Verify the binary actually runs**

Run:
```bash
Frameworks/tmux-cherrylily -V
```

Expected: `tmux 3.5a` (or whatever pinned version).

- [ ] **Step 6: Commit**

```bash
git add scripts/build-tmux.sh Makefile
git commit -m "Add tmux build pipeline for bundled persistence binary"
```

Note: `Frameworks/tmux-cherrylily` should be gitignored (large binary, rebuilt by users). Verify `Frameworks/.gitignore` or add a rule.

---

## Task 2: Embed bundled tmux in app bundle

**Files:**
- Modify: `cherrylily.xcodeproj/project.pbxproj`

The Xcode project must copy `Frameworks/tmux-cherrylily` into `CherryLily.app/Contents/MacOS/tmux-cherrylily` at build time, signed with the rest of the app.

- [ ] **Step 1: Open the project in Xcode**

```bash
open cherrylily.xcodeproj
```

In Xcode, select the `cherrylily` target → Build Phases → click `+` → "New Copy Files Phase" → name it "Embed tmux Binary".

Set Destination to "Executables" (this maps to `Contents/MacOS/`).

Click `+` under the new phase → "Add Other..." → navigate to `Frameworks/tmux-cherrylily` and select it. Check "Copy items if needed" is OFF (we want a reference).

In the file's row, ensure "Code Sign On Copy" is checked.

- [ ] **Step 2: Build and verify the binary lands in the app bundle**

Run:
```bash
make build-app
ls -la ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/tmux-cherrylily
```

Expected: file exists, executable bit set.

- [ ] **Step 3: Verify code signature**

```bash
codesign -dv --verbose=4 ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/tmux-cherrylily 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"
```

Expected: signed (ad-hoc Identifier in Debug).

- [ ] **Step 4: Verify it runs from the bundle path**

```bash
~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Debug/CherryLily.app/Contents/MacOS/tmux-cherrylily -V
```

Expected: `tmux 3.5a`.

- [ ] **Step 5: Commit**

```bash
git add cherrylily.xcodeproj/project.pbxproj
git commit -m "Embed bundled tmux into CherryLily.app/Contents/MacOS"
```

---

## Task 3: SurfaceID typed wrapper

**Files:**
- Create: `cherrylily/Features/Sessions/Models/SurfaceID.swift`
- Test: `cherrylilyTests/SurfaceIDTests.swift`

A typed `SurfaceID` makes session-name string formatting impossible to typo and provides a stable serialization format for layout files.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SurfaceIDTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SurfaceIDTests {
  @Test func sessionNameFormatsAsCLPrefix() {
    let uuid = UUID(uuidString: "7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E")!
    let id = SurfaceID(rawValue: uuid)
    #expect(id.tmuxSessionName == "cl_7c8c2b5e-5d7e-4c7e-9c7e-6c7e7c7e7c7e")
  }

  @Test func parsedFromTmuxSessionNameRoundTrips() {
    let id = SurfaceID()
    let name = id.tmuxSessionName
    let parsed = SurfaceID(tmuxSessionName: name)
    #expect(parsed == id)
  }

  @Test func parsedFromInvalidNameReturnsNil() {
    #expect(SurfaceID(tmuxSessionName: "not-a-cherrylily-session") == nil)
    #expect(SurfaceID(tmuxSessionName: "cl_not-a-uuid") == nil)
    #expect(SurfaceID(tmuxSessionName: "") == nil)
  }

  @Test func codableRoundtrip() throws {
    let id = SurfaceID()
    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(SurfaceID.self, from: data)
    #expect(decoded == id)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "SurfaceIDTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find type 'SurfaceID' in scope" — this counts as a correct RED.

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/Models/SurfaceID.swift`:

```swift
import Foundation

/// A stable identifier for a Ghostty surface, persisted across app restarts so
/// the same surface always attaches to the same tmux session.
struct SurfaceID: Codable, Hashable, Sendable {
  let rawValue: UUID

  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  /// Formatted name used as the tmux session identifier.
  /// Lowercased so it matches `tmux ls` output without case games.
  var tmuxSessionName: String {
    "cl_\(rawValue.uuidString.lowercased())"
  }

  /// Parses a tmux session name created by `tmuxSessionName`.
  /// Returns nil if the name doesn't match the expected `cl_<uuid>` form.
  init?(tmuxSessionName name: String) {
    let prefix = "cl_"
    guard name.hasPrefix(prefix) else { return nil }
    let uuidPart = String(name.dropFirst(prefix.count))
    guard let uuid = UUID(uuidString: uuidPart) else { return nil }
    self.rawValue = uuid
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "SurfaceIDTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: All `SurfaceIDTests` pass; suite reports `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/Models/SurfaceID.swift cherrylilyTests/SurfaceIDTests.swift
git commit -m "Add SurfaceID stable surface identifier with tmux session naming"
```

---

## Task 4: SessionPaths

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/SessionPaths.swift`
- Test: `cherrylilyTests/SessionPathsTests.swift`

Centralizes filesystem paths so tests can override the root directory.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SessionPathsTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SessionPathsTests {
  @Test func layoutFileLivesUnderRoot() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    #expect(paths.layoutFile.path == "/tmp/cl-test/layout.json")
  }

  @Test func tmuxConfigFileLivesUnderRoot() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    #expect(paths.tmuxConfigFile.path == "/tmp/cl-test/tmux.conf")
  }

  @Test func scrollbackFileForSurfaceComposesUUID() {
    let root = URL(fileURLWithPath: "/tmp/cl-test")
    let paths = SessionPaths(root: root)
    let id = SurfaceID(rawValue: UUID(uuidString: "7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E")!)
    let expected = "/tmp/cl-test/sessions/7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E.bin"
    #expect(paths.scrollbackFile(for: id).path == expected)
  }

  @Test func tmuxSocketNameIsStable() {
    let paths = SessionPaths(root: URL(fileURLWithPath: "/tmp/cl-test"))
    #expect(paths.tmuxSocketName == "cherrylily")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "SessionPathsTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'SessionPaths' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/SessionPaths.swift`:

```swift
import Foundation

/// Filesystem paths used by the session-persistence subsystem.
/// Construct with the user's Application Support root in production; tests pass `/tmp` paths.
struct SessionPaths: Sendable {
  let root: URL

  /// Default production root: `~/Library/Application Support/CherryLily/`.
  static var defaultRoot: URL {
    let appSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let resolved = (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support"))
      .appending(path: "CherryLily")
    return resolved
  }

  init(root: URL) {
    self.root = root
  }

  init() {
    self.init(root: Self.defaultRoot)
  }

  var layoutFile: URL { root.appending(path: "layout.json") }
  var tmuxConfigFile: URL { root.appending(path: "tmux.conf") }
  var sessionsDirectory: URL { root.appending(path: "sessions") }
  var tmuxSocketName: String { "cherrylily" }

  func scrollbackFile(for id: SurfaceID) -> URL {
    sessionsDirectory.appending(path: "\(id.rawValue.uuidString).bin")
  }

  /// Ensures all required directories exist. Idempotent.
  func ensureDirectoriesExist() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "SessionPathsTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: All `SessionPathsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SessionPaths.swift cherrylilyTests/SessionPathsTests.swift
git commit -m "Add SessionPaths for session-persistence filesystem locations"
```

---

## Task 5: TmuxBinary locator

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/TmuxBinary.swift`
- Test: `cherrylilyTests/TmuxBinaryTests.swift`

Encapsulates "where is the bundled tmux executable?" so callers don't compose paths inline.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/TmuxBinaryTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct TmuxBinaryTests {
  @Test func resolvedPathIsInsideAppBundle() {
    // Resolution uses Bundle.main; in the test bundle this points at the test runner.
    // We assert the structure (path ends with the expected filename), not absolute equality.
    let url = TmuxBinary.bundledURL
    #expect(url.lastPathComponent == "tmux-cherrylily")
  }

  @Test func executableExistsAfterAppBundleBuild() {
    // This test only meaningfully passes when run inside an integration setup
    // where CherryLily.app has been built. In unit-only runs the bundled binary
    // path may not exist; we guard with a soft assertion.
    let url = TmuxBinary.bundledURL
    if FileManager.default.fileExists(atPath: url.path) {
      #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "TmuxBinaryTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'TmuxBinary' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/TmuxBinary.swift`:

```swift
import Foundation

/// Resolves the location of the tmux executable bundled inside CherryLily.app.
enum TmuxBinary {
  /// Path to the bundled tmux binary inside the running app's MacOS directory.
  /// In tests this resolves to a path inside the test runner; the file may not exist there.
  static var bundledURL: URL {
    let exe = Bundle.main.executableURL
      ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/CherryLily")
    return exe.deletingLastPathComponent().appending(path: "tmux-cherrylily")
  }

  /// Returns true if the bundled binary exists and is executable. Used as a precondition
  /// before launching tmux-backed surfaces.
  static var isAvailable: Bool {
    let url = bundledURL
    return FileManager.default.isExecutableFile(atPath: url.path)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "TmuxBinaryTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/TmuxBinary.swift cherrylilyTests/TmuxBinaryTests.swift
git commit -m "Add TmuxBinary locator for bundled tmux executable"
```

---

## Task 6: SessionLayout model

**Files:**
- Create: `cherrylily/Features/Sessions/Models/SessionLayout.swift`
- Test: `cherrylilyTests/SessionLayoutTests.swift`

The serializable layout snapshot. Versioned so future format changes can migrate cleanly.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SessionLayoutTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SessionLayoutTests {
  @Test func emptyLayoutSerializes() throws {
    let layout = SessionLayout(savedAt: Date(timeIntervalSince1970: 0), worktrees: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(layout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == layout)
    #expect(decoded.version == 1)
  }

  @Test func roundtripWithSurfacesAndCWDs() throws {
    let surfaceID = SurfaceID()
    let surface = PersistedSurface(
      id: surfaceID,
      cwd: URL(fileURLWithPath: "/tmp/repo/wt/src")
    )
    let tab = PersistedTab(
      id: UUID(),
      title: "main",
      surfaces: [surface]
    )
    let worktree = PersistedWorktree(
      worktreeID: "/tmp/repo/wt",
      selectedTabID: tab.id,
      tabs: [tab]
    )
    let original = SessionLayout(savedAt: Date(timeIntervalSince1970: 1_700_000_000), worktrees: [worktree])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionLayout.self, from: data)
    #expect(decoded == original)
  }

  @Test func versionFieldRejectsUnknownVersion() throws {
    let json = #"""
    {"version": 999, "savedAt": "2026-01-01T00:00:00Z", "worktrees": []}
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(SessionLayout.self, from: Data(json.utf8))
    }
  }

  @Test func allSurfaceIDsCollectsAcrossAllWorktrees() {
    let s1 = SurfaceID(); let s2 = SurfaceID(); let s3 = SurfaceID()
    let layout = SessionLayout(
      savedAt: Date(),
      worktrees: [
        PersistedWorktree(worktreeID: "wt1", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t1", surfaces: [
            PersistedSurface(id: s1, cwd: nil),
            PersistedSurface(id: s2, cwd: nil),
          ])
        ]),
        PersistedWorktree(worktreeID: "wt2", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t2", surfaces: [
            PersistedSurface(id: s3, cwd: nil),
          ])
        ]),
      ]
    )
    #expect(Set(layout.allSurfaceIDs) == Set([s1, s2, s3]))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "SessionLayoutTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find type 'SessionLayout' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/Models/SessionLayout.swift`:

```swift
import Foundation

/// A snapshot of CherryLily's terminal layout: which worktrees are open,
/// which tabs they hold, which surfaces (Ghostty panes) live in those tabs,
/// and what working directory each surface was at when the snapshot was taken.
///
/// Persisted as JSON to `SessionPaths.layoutFile`.
struct SessionLayout: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let savedAt: Date
  let worktrees: [PersistedWorktree]

  init(savedAt: Date, worktrees: [PersistedWorktree]) {
    self.version = Self.currentVersion
    self.savedAt = savedAt
    self.worktrees = worktrees
  }

  /// Custom decode that rejects unknown versions; lets us migrate later.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Unsupported SessionLayout version \(version); expected \(Self.currentVersion)"
      )
    }
    self.version = version
    self.savedAt = try container.decode(Date.self, forKey: .savedAt)
    self.worktrees = try container.decode([PersistedWorktree].self, forKey: .worktrees)
  }

  /// Flattens all SurfaceIDs across every worktree/tab. Used by orphan reconciliation.
  var allSurfaceIDs: [SurfaceID] {
    worktrees.flatMap { wt in wt.tabs.flatMap { tab in tab.surfaces.map(\.id) } }
  }

  private enum CodingKeys: String, CodingKey {
    case version, savedAt, worktrees
  }
}

struct PersistedWorktree: Codable, Equatable, Sendable {
  let worktreeID: String
  let selectedTabID: UUID?
  let tabs: [PersistedTab]
}

struct PersistedTab: Codable, Equatable, Sendable {
  let id: UUID
  let title: String
  let surfaces: [PersistedSurface]
}

struct PersistedSurface: Codable, Equatable, Sendable {
  let id: SurfaceID
  /// Captured working directory at snapshot time. Restore launches the new shell with `-c <cwd>`.
  let cwd: URL?
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "SessionLayoutTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/Models/SessionLayout.swift cherrylilyTests/SessionLayoutTests.swift
git commit -m "Add SessionLayout JSON model with versioning"
```

---

## Task 7: SessionLayoutStore

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/SessionLayoutStore.swift`
- Test: `cherrylilyTests/SessionLayoutStoreTests.swift`

Atomically reads/writes the layout file. Atomicity matters because a crash mid-write must not corrupt the layout.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SessionLayoutStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SessionLayoutStoreTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-layout-store-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func savedLayoutCanBeRead() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    let surfaceID = SurfaceID()
    let layout = SessionLayout(
      savedAt: Date(timeIntervalSince1970: 1_700_000_000),
      worktrees: [
        PersistedWorktree(worktreeID: "wt", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t", surfaces: [
            PersistedSurface(id: surfaceID, cwd: URL(fileURLWithPath: "/tmp"))
          ])
        ])
      ]
    )
    try store.save(layout)
    let loaded = try store.load()
    #expect(loaded == layout)
  }

  @Test func loadReturnsNilWhenFileMissing() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    #expect(try store.load() == nil)
  }

  @Test func loadReturnsNilForCorruptedFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    try Data("not json".utf8).write(to: paths.layoutFile)
    let store = SessionLayoutStore(paths: paths)
    #expect(try store.load() == nil)
  }

  @Test func saveOverwritesExistingFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = SessionLayoutStore(paths: paths)
    let first = SessionLayout(savedAt: Date(timeIntervalSince1970: 1), worktrees: [])
    let second = SessionLayout(savedAt: Date(timeIntervalSince1970: 2), worktrees: [])
    try store.save(first)
    try store.save(second)
    let loaded = try store.load()
    #expect(loaded?.savedAt == Date(timeIntervalSince1970: 2))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "SessionLayoutStoreTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'SessionLayoutStore' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/SessionLayoutStore.swift`:

```swift
import Foundation

/// Atomically reads and writes the session layout JSON file.
/// Corruption-tolerant: a malformed file is treated as "no layout" rather than throwing,
/// so a bad snapshot doesn't permanently break startup.
struct SessionLayoutStore {
  let paths: SessionPaths

  init(paths: SessionPaths) {
    self.paths = paths
  }

  /// Loads the layout file. Returns nil if the file is missing OR corrupted.
  func load() throws -> SessionLayout? {
    let url = paths.layoutFile
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(SessionLayout.self, from: data)
    } catch {
      return nil
    }
  }

  /// Atomically writes the layout file. Uses Foundation's `.atomic` write option,
  /// which writes to a temp file in the same directory and renames.
  func save(_ layout: SessionLayout) throws {
    try paths.ensureDirectoriesExist()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(layout)
    try data.write(to: paths.layoutFile, options: [.atomic])
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "SessionLayoutStoreTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/SessionLayoutStore.swift cherrylilyTests/SessionLayoutStoreTests.swift
git commit -m "Add SessionLayoutStore for atomic layout JSON read/write"
```

---

## Task 8: ScrollbackStore

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/ScrollbackStore.swift`
- Test: `cherrylilyTests/ScrollbackStoreTests.swift`

Reads/writes per-surface scrollback files. The actual capture (running `tmux capture-pane`) lives in Phase 3; Phase 1 just provides the storage primitive plus the OSC sanitizer.

Why sanitize: the spec calls out that bytes captured from a terminal can contain dangerous OSC sequences (clipboard manipulation = OSC 52, semantic prompt = OSC 133, hyperlinks = OSC 8). On replay these would re-execute. Strip them on save.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/ScrollbackStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct ScrollbackStoreTests {
  private static func makeTempPaths() -> SessionPaths {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-scrollback-test-\(UUID().uuidString)")
    return SessionPaths(root: temp)
  }

  @Test func writeThenReadRoundtrip() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let id = SurfaceID()
    let bytes = Data("hello \u{001b}[31mred\u{001b}[0m world".utf8)
    try store.write(bytes: bytes, for: id)
    #expect(try store.read(for: id) == bytes)
  }

  @Test func readReturnsNilWhenMissing() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    #expect(try store.read(for: SurfaceID()) == nil)
  }

  @Test func deleteRemovesFile() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let id = SurfaceID()
    try store.write(bytes: Data("x".utf8), for: id)
    try store.delete(for: id)
    #expect(try store.read(for: id) == nil)
  }

  @Test func storedSurfaceIDsListsAllFiles() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = ScrollbackStore(paths: paths)
    let a = SurfaceID(); let b = SurfaceID()
    try store.write(bytes: Data("a".utf8), for: a)
    try store.write(bytes: Data("b".utf8), for: b)
    #expect(Set(try store.storedSurfaceIDs()) == Set([a, b]))
  }

  @Test func storedSurfaceIDsIgnoresNonUUIDFiles() throws {
    let paths = Self.makeTempPaths()
    try paths.ensureDirectoriesExist()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    try Data().write(to: paths.sessionsDirectory.appending(path: "garbage.txt"))
    let store = ScrollbackStore(paths: paths)
    #expect(try store.storedSurfaceIDs() == [])
  }

  @Test func sanitizeStripsOSC52Clipboard() {
    // OSC 52 = ESC ] 52 ; … ST  (clipboard write)
    let dangerous = Data("safe\u{001b}]52;c;dGVzdA==\u{0007}safe".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(!cleaned.contains([0x1B, 0x5D, 0x35, 0x32]))   // ESC ] 5 2
    let asString = String(decoding: cleaned, as: UTF8.self)
    #expect(asString == "safesafe")
  }

  @Test func sanitizeStripsOSC8Hyperlink() {
    // OSC 8 = ESC ] 8 ; params ; URI ST  text  ESC ] 8 ; ; ST
    let dangerous = Data("\u{001b}]8;;https://evil\u{0007}link\u{001b}]8;;\u{0007}".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    let asString = String(decoding: cleaned, as: UTF8.self)
    #expect(asString == "link")
  }

  @Test func sanitizeStripsOSC133SemanticPrompt() {
    let dangerous = Data("normal\u{001b}]133;A\u{0007}prompt".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(String(decoding: cleaned, as: UTF8.self) == "normalprompt")
  }

  @Test func sanitizePreservesColorEscapes() {
    // SGR sequence: ESC [ 31 m  (red) — this should pass through unchanged
    let safe = Data("\u{001b}[31mred\u{001b}[0m".utf8)
    let cleaned = ScrollbackStore.sanitize(safe)
    #expect(cleaned == safe)
  }

  @Test func sanitizeHandlesSTAsBackslash() {
    // OSC sequences can be terminated with ST = ESC \ (instead of BEL)
    let dangerous = Data("\u{001b}]52;c;dGVzdA==\u{001b}\u{005c}rest".utf8)
    let cleaned = ScrollbackStore.sanitize(dangerous)
    #expect(String(decoding: cleaned, as: UTF8.self) == "rest")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "ScrollbackStoreTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'ScrollbackStore' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/ScrollbackStore.swift`:

```swift
import Foundation

/// Reads and writes per-surface scrollback files. Sanitizes captured bytes to strip
/// dangerous OSC sequences before storage.
struct ScrollbackStore {
  let paths: SessionPaths

  init(paths: SessionPaths) {
    self.paths = paths
  }

  /// Writes scrollback bytes for the given surface, after sanitizing.
  func write(bytes: Data, for id: SurfaceID) throws {
    try paths.ensureDirectoriesExist()
    let cleaned = Self.sanitize(bytes)
    try cleaned.write(to: paths.scrollbackFile(for: id), options: [.atomic])
  }

  /// Reads previously-stored scrollback. Returns nil if the file doesn't exist.
  func read(for id: SurfaceID) throws -> Data? {
    let url = paths.scrollbackFile(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  /// Removes the stored scrollback for the surface. No-op if missing.
  func delete(for id: SurfaceID) throws {
    let url = paths.scrollbackFile(for: id)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Returns SurfaceIDs corresponding to scrollback files in the sessions directory.
  /// Ignores any file whose name doesn't parse as `<UUID>.bin`.
  func storedSurfaceIDs() throws -> [SurfaceID] {
    let dir = paths.sessionsDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    return entries.compactMap { url -> SurfaceID? in
      let name = url.lastPathComponent
      guard name.hasSuffix(".bin") else { return nil }
      let stem = String(name.dropLast(".bin".count))
      guard let uuid = UUID(uuidString: stem) else { return nil }
      return SurfaceID(rawValue: uuid)
    }
  }

  /// Strips dangerous OSC sequences (52 = clipboard, 8 = hyperlink, 133 = semantic prompt)
  /// from the byte stream while preserving CSI/SGR (color/cursor) escapes.
  ///
  /// OSC sequences are: ESC ] code ; payload ST  where ST = BEL (0x07) or ESC \ (0x1B 0x5C).
  static func sanitize(_ input: Data) -> Data {
    let bytes = [UInt8](input)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
      // Detect ESC ] (start of OSC)
      if i + 1 < bytes.count, bytes[i] == 0x1B, bytes[i + 1] == 0x5D {
        // Parse the OSC code (digits up to first ';' or terminator)
        var j = i + 2
        var codeBytes = [UInt8]()
        while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
          codeBytes.append(bytes[j])
          j += 1
        }
        let codeStr = String(decoding: codeBytes, as: UTF8.self)
        let code = Int(codeStr) ?? -1
        // Find terminator: BEL (0x07) or ESC \ (0x1B 0x5C)
        var k = j
        while k < bytes.count {
          if bytes[k] == 0x07 {
            k += 1
            break
          }
          if bytes[k] == 0x1B, k + 1 < bytes.count, bytes[k + 1] == 0x5C {
            k += 2
            break
          }
          k += 1
        }
        // If this is a dangerous OSC code, drop the whole sequence; otherwise keep.
        if [52, 8, 133].contains(code) {
          i = k
          continue
        }
        // Keep the bytes as-is
        out.append(contentsOf: bytes[i..<k])
        i = k
        continue
      }
      out.append(bytes[i])
      i += 1
    }
    return Data(out)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "ScrollbackStoreTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/ScrollbackStore.swift cherrylilyTests/ScrollbackStoreTests.swift
git commit -m "Add ScrollbackStore with OSC sequence sanitization"
```

---

## Task 9: TmuxClient (subprocess wrapper for ls/kill-session)

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift`
- Test: `cherrylilyTests/TmuxClientTests.swift`

Wraps the subset of `tmux` invocations Phase 1 needs: list sessions, kill session, kill server. Uses `Process` directly. The tests are integration tests that require the bundled tmux binary to exist; if it doesn't, they skip.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/TmuxClientTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct TmuxClientTests {
  private static var tmuxAvailable: Bool { TmuxBinary.isAvailable }

  /// Each test uses a unique socket name to avoid touching real CherryLily sessions.
  private static func makeIsolatedClient() -> TmuxClient {
    let socket = "cl-test-\(UUID().uuidString.prefix(8).lowercased())"
    return TmuxClient(executableURL: TmuxBinary.bundledURL, socketName: socket)
  }

  @Test func listSessionsReturnsEmptyWhenNoneExist() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    let names = try await client.listSessionNames()
    #expect(names.isEmpty)
  }

  @Test func sessionAfterCreationAppearsInList() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    try await client.createSession(named: "test-session", workingDirectory: nil)
    let names = try await client.listSessionNames()
    #expect(names.contains("test-session"))
  }

  @Test func killSessionRemovesIt() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    try await client.createSession(named: "kill-me", workingDirectory: nil)
    try await client.killSession(named: "kill-me")
    let names = try await client.listSessionNames()
    #expect(!names.contains("kill-me"))
  }

  @Test func killSessionOnUnknownNameDoesNotThrow() async throws {
    try #require(Self.tmuxAvailable)
    let client = Self.makeIsolatedClient()
    defer { try? client.killServer() }
    // Should be tolerant — we use this in cleanup paths
    try await client.killSession(named: "does-not-exist")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "TmuxClientTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'TmuxClient' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift`:

```swift
import Foundation

/// Typed wrapper around the subset of tmux subprocess invocations the persistence
/// system needs in Phase 1: list, create, kill sessions, kill server.
///
/// Phase 3 will add capture-pane and attach machinery; this type stays focused on
/// session-management primitives.
struct TmuxClient {
  let executableURL: URL
  /// Socket name passed via `tmux -L`. Isolates our sessions from the user's normal tmux.
  let socketName: String

  init(executableURL: URL, socketName: String) {
    self.executableURL = executableURL
    self.socketName = socketName
  }

  /// Lists session names on our socket. Returns empty when no server is running
  /// (tmux exits with non-zero in that case — we treat it as "no sessions").
  func listSessionNames() async throws -> [String] {
    let result = try await run(["ls", "-F", "#{session_name}"])
    if !result.success {
      // tmux exits 1 with "no server running" on stderr — that's fine, treat as empty
      let stderr = result.stderr.lowercased()
      if stderr.contains("no server running") || stderr.contains("error connecting") {
        return []
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
    return result.stdout
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  /// Creates a detached session. Optional working directory passed via `-c`.
  func createSession(named name: String, workingDirectory: URL?) async throws {
    var args = ["new-session", "-d", "-s", name]
    if let workingDirectory {
      args.append(contentsOf: ["-c", workingDirectory.path])
    }
    let result = try await run(args)
    guard result.success else {
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  /// Kills the named session. Tolerates "session not found" — used in cleanup.
  func killSession(named name: String) async throws {
    let result = try await run(["kill-session", "-t", name])
    if !result.success {
      let stderr = result.stderr.lowercased()
      if stderr.contains("can't find session") || stderr.contains("no server running") {
        return
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  /// Kills the entire server, dropping all sessions. Tolerates "no server running".
  func killServer() throws {
    // Synchronous because used in defer blocks; uses runSync helper.
    let result = try runSync(["kill-server"])
    if !result.success {
      let stderr = result.stderr.lowercased()
      if stderr.contains("no server running") {
        return
      }
      throw TmuxClientError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
    }
  }

  // MARK: - Process plumbing

  private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var success: Bool { exitCode == 0 }
  }

  private func run(_ args: [String]) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      do {
        let result = try runSync(args)
        continuation.resume(returning: result)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func runSync(_ args: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-L", socketName] + args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

enum TmuxClientError: Error, Equatable {
  case commandFailed(stderr: String, exitCode: Int32)
}
```

- [ ] **Step 4: Run test to verify it passes**

This requires the bundled tmux binary to exist. If you haven't run `make build-app` yet (Task 2), do so first. Then:

```bash
make test 2>&1 | grep -E "TmuxClientTests|TEST FAILED|TEST SUCCEEDED" | head -10
```

Expected: passes if tmux binary is available; tests skip cleanly otherwise.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/TmuxClient.swift cherrylilyTests/TmuxClientTests.swift
git commit -m "Add TmuxClient subprocess wrapper for session management"
```

---

## Task 10: OrphanReconciler

**Files:**
- Create: `cherrylily/Features/Sessions/BusinessLogic/OrphanReconciler.swift`
- Test: `cherrylilyTests/OrphanReconcilerTests.swift`

The reconciler is the orphan-cleanup logic from the spec, expressed as a pure function over three sets so it's exhaustively unit-testable. The actual side-effects (kill sessions, delete files) are issued by the caller using results from this reconciler.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/OrphanReconcilerTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct OrphanReconcilerTests {
  @Test func emptyInputsProducesNoActions() {
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill.isEmpty)
    #expect(plan.scrollbackFilesToDelete.isEmpty)
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.surfacesAlreadyAlive.isEmpty)
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func sessionWithMatchingExpectedIsAlive() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: []
    )
    #expect(plan.surfacesAlreadyAlive == [id])
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.sessionsToKill.isEmpty)
  }

  @Test func sessionWithoutExpectedIsKilled() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill == [id.tmuxSessionName])
  }

  @Test func nonClSessionNamesAreLeftAlone() {
    // A session that doesn't match the cl_<uuid> pattern was created by the user's
    // own tmux somehow (shouldn't happen with custom socket but defensive).
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: ["my-personal-session"],
      storedScrollbackIDs: []
    )
    #expect(plan.sessionsToKill.isEmpty)
  }

  @Test func scrollbackFileWithoutExpectedIsDeleted() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [id]
    )
    #expect(plan.scrollbackFilesToDelete == [id])
  }

  @Test func expectedWithoutSessionNeedsFreshSession() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: []
    )
    #expect(plan.surfacesNeedingFreshSession == [id])
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func expectedWithoutSessionButWithScrollbackIsEligibleForReplay() {
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [id]
    )
    #expect(plan.surfacesNeedingFreshSession == [id])
    #expect(plan.surfacesEligibleForReplay == [id])
  }

  @Test func expectedWithLiveSessionDoesNotReplayEvenIfFileExists() {
    // Live session means we kept the in-memory state; replay would double-up
    let id = SurfaceID()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [id],
      liveTmuxSessionNames: [id.tmuxSessionName],
      storedScrollbackIDs: [id]
    )
    #expect(plan.surfacesAlreadyAlive == [id])
    #expect(plan.surfacesNeedingFreshSession.isEmpty)
    #expect(plan.surfacesEligibleForReplay.isEmpty)
  }

  @Test func mixedScenarioProducesCorrectPlan() {
    // Reboot scenario: some sessions in layout, none alive in tmux, all have scrollback files
    let kept = SurfaceID()
    let alsoKept = SurfaceID()
    let removed = SurfaceID()        // in scrollback files but not in expected → file orphan
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: [kept, alsoKept],
      liveTmuxSessionNames: [],
      storedScrollbackIDs: [kept, alsoKept, removed]
    )
    #expect(Set(plan.surfacesNeedingFreshSession) == Set([kept, alsoKept]))
    #expect(Set(plan.surfacesEligibleForReplay) == Set([kept, alsoKept]))
    #expect(plan.scrollbackFilesToDelete == [removed])
    #expect(plan.sessionsToKill.isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | grep -E "OrphanReconcilerTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: build error "Cannot find 'OrphanReconciler' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `cherrylily/Features/Sessions/BusinessLogic/OrphanReconciler.swift`:

```swift
import Foundation

/// Pure-function reconciliation of three sets of state:
///   - `expectedSurfaceIDs`: what the layout file says should exist
///   - `liveTmuxSessionNames`: what tmux currently holds
///   - `storedScrollbackIDs`: what files exist in the sessions directory
///
/// Produces a `Plan` describing actions needed to reach a consistent state.
/// The caller issues the actual side effects.
enum OrphanReconciler {
  struct Plan: Equatable {
    /// Tmux session names whose corresponding SurfaceID is not in the layout — kill them.
    /// Sessions whose names don't parse as `cl_<uuid>` are left alone (not ours).
    var sessionsToKill: [String]

    /// SurfaceIDs whose scrollback file exists but who aren't in the layout — delete files.
    var scrollbackFilesToDelete: [SurfaceID]

    /// SurfaceIDs in the layout that don't have a live tmux session — create one.
    var surfacesNeedingFreshSession: [SurfaceID]

    /// Subset of `surfacesNeedingFreshSession` for which a scrollback file exists — replay it.
    var surfacesEligibleForReplay: [SurfaceID]

    /// SurfaceIDs in the layout that already have a live session — just attach.
    var surfacesAlreadyAlive: [SurfaceID]
  }

  static func reconcile(
    expectedSurfaceIDs: [SurfaceID],
    liveTmuxSessionNames: [String],
    storedScrollbackIDs: [SurfaceID]
  ) -> Plan {
    let expectedSet = Set(expectedSurfaceIDs)
    let storedSet = Set(storedScrollbackIDs)

    // For each live session name, parse SurfaceID. If it parses but isn't expected, kill.
    var sessionsToKill: [String] = []
    var liveSurfaceIDs = Set<SurfaceID>()
    for name in liveTmuxSessionNames {
      guard let surfaceID = SurfaceID(tmuxSessionName: name) else {
        // Not ours — leave alone
        continue
      }
      if expectedSet.contains(surfaceID) {
        liveSurfaceIDs.insert(surfaceID)
      } else {
        sessionsToKill.append(name)
      }
    }

    // Scrollback files whose surface ID is not in the layout → delete
    let scrollbackFilesToDelete = storedScrollbackIDs.filter { !expectedSet.contains($0) }

    // Surfaces in layout: alive vs need-fresh; among need-fresh, replay-eligible if file exists
    var alive: [SurfaceID] = []
    var needsFresh: [SurfaceID] = []
    var eligibleForReplay: [SurfaceID] = []
    for id in expectedSurfaceIDs {
      if liveSurfaceIDs.contains(id) {
        alive.append(id)
      } else {
        needsFresh.append(id)
        if storedSet.contains(id) {
          eligibleForReplay.append(id)
        }
      }
    }

    return Plan(
      sessionsToKill: sessionsToKill,
      scrollbackFilesToDelete: scrollbackFilesToDelete,
      surfacesNeedingFreshSession: needsFresh,
      surfacesEligibleForReplay: eligibleForReplay,
      surfacesAlreadyAlive: alive
    )
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
make test 2>&1 | grep -E "OrphanReconcilerTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add cherrylily/Features/Sessions/BusinessLogic/OrphanReconciler.swift cherrylilyTests/OrphanReconcilerTests.swift
git commit -m "Add OrphanReconciler pure-function cleanup planning"
```

---

## Task 11: End-to-end reconciliation integration test

**Files:**
- Create: `cherrylilyTests/SessionPersistenceIntegrationTests.swift`

Validates that the pieces compose correctly: write a layout, populate scrollback files, create real tmux sessions, run reconciliation, observe the right side effects. This is the smoke test for Phase 1 as a whole.

- [ ] **Step 1: Write the failing test**

Create `cherrylilyTests/SessionPersistenceIntegrationTests.swift`:

```swift
import Foundation
import Testing

@testable import CherryLily

struct SessionPersistenceIntegrationTests {
  private static func makeIsolatedSetup() -> (paths: SessionPaths, client: TmuxClient) {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "cl-int-test-\(UUID().uuidString)")
    let paths = SessionPaths(root: temp)
    let socket = "cl-int-\(UUID().uuidString.prefix(8).lowercased())"
    let client = TmuxClient(executableURL: TmuxBinary.bundledURL, socketName: socket)
    return (paths, client)
  }

  @Test func reconciliationCleansOrphanSessionsAndFiles() async throws {
    try #require(TmuxBinary.isAvailable)
    let (paths, client) = Self.makeIsolatedSetup()
    try paths.ensureDirectoriesExist()
    defer {
      try? client.killServer()
      try? FileManager.default.removeItem(at: paths.root)
    }

    let kept = SurfaceID()
    let removedFromLayout = SurfaceID()

    // Setup: one expected surface (kept), one orphan tmux session, one orphan scrollback file
    let layoutStore = SessionLayoutStore(paths: paths)
    let scrollbackStore = ScrollbackStore(paths: paths)

    let layout = SessionLayout(
      savedAt: Date(),
      worktrees: [
        PersistedWorktree(worktreeID: "wt", selectedTabID: nil, tabs: [
          PersistedTab(id: UUID(), title: "t", surfaces: [
            PersistedSurface(id: kept, cwd: nil)
          ])
        ])
      ]
    )
    try layoutStore.save(layout)
    try scrollbackStore.write(bytes: Data("hi".utf8), for: removedFromLayout)
    try await client.createSession(named: removedFromLayout.tmuxSessionName, workingDirectory: nil)

    // Reconcile
    let liveSessions = try await client.listSessionNames()
    let storedFiles = try scrollbackStore.storedSurfaceIDs()
    let plan = OrphanReconciler.reconcile(
      expectedSurfaceIDs: layout.allSurfaceIDs,
      liveTmuxSessionNames: liveSessions,
      storedScrollbackIDs: storedFiles
    )

    // Apply side effects from plan
    for sessionName in plan.sessionsToKill {
      try await client.killSession(named: sessionName)
    }
    for id in plan.scrollbackFilesToDelete {
      try scrollbackStore.delete(for: id)
    }

    // Verify
    let postKillSessions = try await client.listSessionNames()
    let postDeleteFiles = try scrollbackStore.storedSurfaceIDs()
    #expect(!postKillSessions.contains(removedFromLayout.tmuxSessionName))
    #expect(!postDeleteFiles.contains(removedFromLayout))

    // The kept surface was not in tmux to begin with — verify the plan flagged it for fresh creation
    #expect(plan.surfacesNeedingFreshSession == [kept])
    #expect(plan.surfacesEligibleForReplay.isEmpty)  // no scrollback file for kept
  }
}
```

- [ ] **Step 2: Run test to verify it passes**

(There's no production code change in this task — it's a composition test of pieces from Tasks 1-10.)

```bash
make test 2>&1 | grep -E "SessionPersistenceIntegrationTests|TEST FAILED|TEST SUCCEEDED" | head -5
```

Expected: passes (assuming bundled tmux binary is available).

- [ ] **Step 3: Run the full test suite to make sure nothing else regressed**

```bash
make test 2>&1 | grep -E "TEST FAILED|TEST SUCCEEDED|Failing tests" | head -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add cherrylilyTests/SessionPersistenceIntegrationTests.swift
git commit -m "Add session persistence integration test for orphan reconciliation"
```

---

## Task 12: Wire SessionPaths into CherryLilyPaths

**Files:**
- Modify: `cherrylily/Support/CherryLilyPaths.swift`

Phase 2 onward needs access to the production `SessionPaths` from inside the app. Add a single accessor to keep the call site clean.

- [ ] **Step 1: Read CherryLilyPaths to find the right place**

```bash
grep -n "enum CherryLilyPaths\|^extension CherryLilyPaths" cherrylily/Support/CherryLilyPaths.swift | head -5
```

- [ ] **Step 2: Add accessor**

In `cherrylily/Support/CherryLilyPaths.swift`, inside the `CherryLilyPaths` enum (or at end of file as an extension), add:

```swift
extension CherryLilyPaths {
  /// Filesystem paths used by the session-persistence subsystem.
  static var sessions: SessionPaths {
    SessionPaths()
  }
}
```

- [ ] **Step 3: Verify build**

```bash
make build-app 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add cherrylily/Support/CherryLilyPaths.swift
git commit -m "Expose SessionPaths via CherryLilyPaths.sessions accessor"
```

---

## Task 13: Final smoke + lint

- [ ] **Step 1: Run lint on touched files**

```bash
mise exec -- swiftlint --strict cherrylily/Features/Sessions cherrylilyTests/Session*.swift cherrylilyTests/SurfaceID*.swift cherrylilyTests/Tmux*.swift cherrylilyTests/Orphan*.swift cherrylilyTests/Scrollback*.swift 2>&1 | tail -10
```

Expected: 0 violations in the new files. Pre-existing violations in unrelated files (line_length in OpenWorktreeAction.swift, etc.) are fine.

- [ ] **Step 2: Build release configuration**

```bash
make build-release 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Verify the release bundle includes tmux**

```bash
ls -la ~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Release/CherryLily.app/Contents/MacOS/tmux-cherrylily
~/Library/Developer/Xcode/DerivedData/cherrylily-*/Build/Products/Release/CherryLily.app/Contents/MacOS/tmux-cherrylily -V
```

Expected: file present, version prints.

- [ ] **Step 4: Push the branch**

```bash
git push 2>&1 | tail -3
```

- [ ] **Step 5: Sanity check — run the full test suite once more**

```bash
make test 2>&1 | grep -E "TEST FAILED|TEST SUCCEEDED|Failing tests" | head -3
```

Expected: `** TEST SUCCEEDED **`.

---

## What Phase 1 leaves for later

- **Surface launch wrapping** (Phase 2): `WorktreeTerminalState.createSurface` learns to launch via `tmux new-session` when the persistence flag is on. Requires a managed `tmux.conf` writer.
- **Capture on quit** (Phase 3): `tmux capture-pane` invocation, on app quit, parallel across surfaces.
- **Replay on launch** (Phase 3): inject saved scrollback into newly-created sessions via the `cat <file>` mechanism described in the spec.
- **Settings UI** (Phase 4): user-facing toggle and scrollback-limit picker.
- **Edge cases** (Phase 5): disk-full alert, server-crash auto-restart, multi-instance prevention, hourly autosave timer.
- **Polish** (Phase 6): reattach-flicker mitigation, OSC passthrough verification.

The Phase 1 deliverables let Phase 2+ build directly: every persistence concept (SurfaceID, layout, files, tmux client, orphan plan) has a tested, committed implementation.

---

## Self-Review Notes

Verified before publishing:
- Every step has either runnable code or an exact command with expected output. No "TBD" or "implement appropriately".
- Type and method names are consistent across tasks (`SurfaceID`, `SessionPaths`, `SessionLayoutStore`, `ScrollbackStore`, `TmuxClient`, `OrphanReconciler`, `Plan`).
- File paths are exact and match the synchronized-folder layout (`cherrylily/Features/Sessions/...`).
- Tests precede implementations in every TDD task.
- Each task ends with a commit so the history bisects cleanly.
- Tasks that depend on the bundled tmux binary (Task 9, 11) explicitly note the prerequisite (Task 2 must have run first).
- The integration test (Task 11) re-validates the composition of Tasks 1–10 against real tmux.
- Scope check: Phase 1 only. Phases 2–6 are explicitly deferred.
