//
//  cherrylilyApp.swift
//  cherrylily
//
//  Created by khoi on 20/1/26.
//

import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
import Sharing
import SwiftUI

private enum GhosttyCLI {
  static let argv: [UnsafeMutablePointer<CChar>?] = {
    @Shared(.settingsFile) var settingsFile
    let overrides = settingsFile.global.shortcutOverrides
    var args: [UnsafeMutablePointer<CChar>?] = []
    let executable = CommandLine.arguments.first ?? "cherrylily"
    args.append(strdup(executable))
    for keybindArgument in AppShortcuts.ghosttyCLIKeybindArguments(from: overrides) {
      args.append(strdup(keybindArgument))
    }
    args.append(nil)
    return args
  }()
}

@MainActor
final class CherryLilyAppDelegate: NSObject, NSApplicationDelegate {
  static let diskFullObservedKey = "cl.session.diskFullObserved"

  var appStore: StoreOf<AppFeature>? {
    didSet {
      guard let appStore else { return }
      // Replay any deeplinks that arrived before the store was initialized.
      let buffered = bufferedDeeplinkURLs
      bufferedDeeplinkURLs.removeAll()
      for url in buffered {
        appStore.send(.deeplinkReceived(url))
      }
    }
  }
  var terminalManager: WorktreeTerminalManager?
  var persistence: SessionPersistence?
  var autosaveTimer: HourlyAutosaveTimer?
  var healthMonitor: TmuxHealthMonitor?
  private var bufferedDeeplinkURLs: [URL] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Single-instance guard. Runs BEFORE we touch the tmux socket or build the
    // terminal manager — if a second copy of CherryLily launches while one is
    // already running, this brings the first instance to the front and calls
    // NSApp.terminate(nil), which does not return.
    //
    // Skip under XCTest: the test runner hosts itself inside the app binary, so
    // this fires during test bootstrap. Without the skip the test process loses
    // the lock race against the user's live Release build and terminates itself
    // before XCTest can connect.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      InstanceLock.acquireOrTerminate()
    }
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false,
    ])
    startAutosaveTimerIfNeeded()
    startHealthMonitorIfNeeded()
    checkDiskFullOnLastQuit()
    appStore?.send(.appLaunched)
  }

  /// If the last quit's `captureAll` saw any ENOSPC failures, the app delegate
  /// flips a UserDefaults flag (see `applicationWillTerminate`). On next launch
  /// we show a one-time alert per the design spec, then clear the flag so the
  /// alert appears at most once per disk-full event.
  private func checkDiskFullOnLastQuit() {
    let key = Self.diskFullObservedKey
    guard UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(false, forKey: key)
    // Defer to next runloop so the alert appears after the main window comes up.
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "Could not save terminal contents"
      alert.informativeText =
        "CherryLily ran out of disk space while saving your terminal scrollback on the last quit. "
        + "Free some space to ensure future sessions are saved."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// Hourly autosave: timer always runs, but the snapshot closure short-circuits
  /// (returns nil) whenever the user disables `hourlyAutosaveEnabled`. That keeps
  /// us from plumbing settings-change events through the reducer just to toggle a
  /// timer — the cost is one wake-up per hour even when disabled, which is
  /// negligible. `captureAll` no-ops on a nil layout because we just don't call it.
  private func startAutosaveTimerIfNeeded() {
    guard let persistence, let terminalManager, autosaveTimer == nil else { return }
    let timer = HourlyAutosaveTimer(
      persistence: persistence,
      snapshot: { [terminalManager] in
        @Shared(.settingsFile) var settingsFile
        guard settingsFile.global.hourlyAutosaveEnabled else { return nil }
        let states = terminalManager.allWorktreeStates.map {
          (id, state) -> (Worktree.ID, any WorktreeStateSnapshotting) in
          (id, state as any WorktreeStateSnapshotting)
        }
        return LayoutSnapshotBuilder.build(worktreeStates: states, now: Date())
      },
      scrollbackLimit: {
        @Shared(.settingsFile) var settingsFile
        return settingsFile.global.sessionScrollbackLimit
      }
    )
    timer.start()
    autosaveTimer = timer
  }

  /// Background-poll tmux liveness so we can log when the server has crashed.
  /// This is observe-and-log only; the UI work to recover surviving terminals
  /// after a crash is a separate follow-up. Guarded on persistence being
  /// configured AND the user having opted into session restore — if they don't
  /// care about persistence, polling tmux is pure overhead.
  private func startHealthMonitorIfNeeded() {
    guard healthMonitor == nil, let persistence else { return }
    @Shared(.settingsFile) var settings
    guard settings.global.restoreSessionsOnLaunch else { return }
    let monitor = TmuxHealthMonitor(
      tmuxClient: TmuxClient(
        executableURL: TmuxBinary.bundledURL,
        socketName: persistence.paths.tmuxSocketName
      ),
      onCrash: {
        SupaLogger("Sessions").warning(
          "tmux server appears to have crashed (2 consecutive ping failures); "
            + "live terminals may not respond. Restart CherryLily to recover."
        )
      }
    )
    monitor.start()
    healthMonitor = monitor
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    let app = NSApplication.shared
    guard !app.windows.contains(where: \.isVisible) else { return }
    _ = showMainWindow(from: app)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag { return true }
    return showMainWindow(from: sender) ? false : true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let appStore else {
      SupaLogger("Deeplink").warning("Deeplink received before store initialized, buffering: \(urls)")
      bufferedDeeplinkURLs.append(contentsOf: urls)
      return
    }
    for url in urls {
      appStore.send(.deeplinkReceived(url))
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    autosaveTimer?.stop()
    healthMonitor?.stop()
    guard let persistence, let terminalManager else { return }
    @Shared(.settingsFile) var settings
    guard settings.global.restoreSessionsOnLaunch else { return }
    let scrollbackLimit = settings.global.sessionScrollbackLimit

    let states = terminalManager.allWorktreeStates.map { (id, state) -> (Worktree.ID, any WorktreeStateSnapshotting) in
      (id, state as any WorktreeStateSnapshotting)
    }
    let layout = LayoutSnapshotBuilder.build(
      worktreeStates: states,
      now: Date()
    )

    do {
      try persistence.writeLayout(layout)
    } catch {
      SupaLogger("Sessions").warning("layout write on quit failed: \(error)")
    }

    // Capture is async; we synchronously wait up to 2 seconds before letting
    // macOS SIGKILL us. DispatchSemaphore because this delegate method is sync.
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      let report = await persistence.captureAll(for: layout, scrollbackLimit: scrollbackLimit)
      if report.diskFullCount > 0 {
        UserDefaults.standard.set(true, forKey: Self.diskFullObservedKey)
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(2))
  }

  private func mainWindow(from sender: NSApplication) -> NSWindow? {
    if let window = sender.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
      return window
    }
    if let window = sender.windows.first(where: { $0.identifier?.rawValue != WindowID.settings }) {
      return window
    }
    return sender.windows.first
  }

  private func showMainWindow(from sender: NSApplication) -> Bool {
    guard let window = mainWindow(from: sender) else { return false }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    sender.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }
}

@main
@MainActor
struct CherryLilyApp: App {
  @NSApplicationDelegateAdaptor(CherryLilyAppDelegate.self) private var appDelegate
  @State private var ghostty: GhosttyRuntime
  @State private var ghosttyShortcuts: GhosttyShortcutManager
  @State private var terminalManager: WorktreeTerminalManager
  @State private var worktreeInfoWatcher: WorktreeInfoWatcherManager
  @State private var commandKeyObserver: CommandKeyObserver
  @State private var store: StoreOf<AppFeature>

  // swiftlint:disable:next function_body_length
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  @MainActor init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
    @Shared(.settingsFile) var settingsFile
    let initialSettings = settingsFile.global
    #if !DEBUG
    #endif
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
      setenv("GHOSTTY_RESOURCES_DIR", resourceURL.path, 1)
    }
    GhosttyCLI.argv.withUnsafeBufferPointer { buffer in
      let argc = UInt(max(0, buffer.count - 1))
      let argv = UnsafeMutablePointer(mutating: buffer.baseAddress)
      if ghostty_init(argc, argv) != GHOSTTY_SUCCESS {
        preconditionFailure("ghostty_init failed")
      }
    }
    let runtime = GhosttyRuntime()
    _ghostty = State(initialValue: runtime)
    let shortcuts = GhosttyShortcutManager(runtime: runtime)
    _ghosttyShortcuts = State(initialValue: shortcuts)
    // Under XCTest, the test runner hosts itself inside this app binary. If we
    // touch the production tmux socket here, reconcileOrphans below will treat
    // the user's live `cl_*` sessions as orphans (the test-hosted state never
    // matches reality) and kill them. Same env-var sentinel as InstanceLock.
    let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let persistence: SessionPersistence? = isUnderTest ? nil : SessionPersistence(paths: SessionPaths())
    let terminalManager = WorktreeTerminalManager(
      runtime: runtime,
      persistenceEnabled: {
        if isUnderTest { return false }
        @Shared(.settingsFile) var settingsFile
        return settingsFile.global.restoreSessionsOnLaunch
      },
      persistence: persistence,
    )
    if !isUnderTest, initialSettings.restoreSessionsOnLaunch, let persistence {
      Self.bootstrapSessionPersistence(
        persistence: persistence,
        scrollbackLimit: initialSettings.sessionScrollbackLimit
      )
    }
    _terminalManager = State(initialValue: terminalManager)
    if !isUnderTest {
      terminalManager.loadLayoutOnLaunch()
    }
    if !isUnderTest, initialSettings.restoreSessionsOnLaunch, let persistence {
      // Always reconcile when restore is enabled — an empty/missing layout means
      // every live `cl_<uuid>` session on the socket is by definition an orphan
      // (nothing expects them anymore). Skipping reconciliation would leak those
      // sessions across launches.
      let layout = terminalManager.loadedLayout
        ?? SessionLayout(savedAt: Date(), worktrees: [])
      Task {
        await persistence.reconcileOrphans(against: layout)
      }
    }
    let worktreeInfoWatcher = WorktreeInfoWatcherManager()
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let keyObserver = CommandKeyObserver()
    keyObserver.isEnabled = initialSettings.showShortcutHints
    _commandKeyObserver = State(initialValue: keyObserver)
    let appStore = Store(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: initialSettings))
    ) {
      #if DEBUG
        AppFeature()
          .logActions()
      #else
        AppFeature()
      #endif
    } withDependencies: { values in
      values.terminalClient = TerminalClient(
        send: { command in
          terminalManager.handleCommand(command)
        },
        events: {
          terminalManager.eventStream()
        },
        currentTabID: { worktreeID in
          terminalManager.currentTabID(worktreeID: worktreeID)
        },
        tabExists: { worktreeID, tabID in
          terminalManager.tabExists(worktreeID: worktreeID, tabID: tabID)
        },
        surfaceExists: { worktreeID, tabID, surfaceID in
          terminalManager.surfaceExists(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID)
        },
        surfaceExistsInWorktree: { worktreeID, surfaceID in
          terminalManager.surfaceExistsInWorktree(worktreeID: worktreeID, surfaceID: surfaceID)
        },
        tabTitle: { worktreeID, tabID in
          terminalManager.tabTitle(worktreeID: worktreeID, tabID: tabID)
        },
        tabCount: { worktreeID in
          terminalManager.tabCount(worktreeID: worktreeID)
        },
        tabIndex: { worktreeID, tabID in
          terminalManager.tabIndex(worktreeID: worktreeID, tabID: tabID)
        }
      )
      values.worktreeInfoWatcher = WorktreeInfoWatcherClient(
        send: { command in
          worktreeInfoWatcher.handleCommand(command)
        },
        events: {
          worktreeInfoWatcher.eventStream()
        }
      )
    }
    _store = State(initialValue: appStore)
    appDelegate.appStore = appStore
    appDelegate.terminalManager = terminalManager
    // Forward CLI socket commands to the TCA store as deeplinks.
    // The responseFD is threaded through the action chain so the reducer
    // can respond after processing (or after a confirmation dialog resolves).
    let store = appStore
    terminalManager.onDeeplinkCommand = { url, clientFD in
      store.send(.deeplinkReceived(url, source: .socket, responseFD: clientFD))
    }
    // Handle CLI queries by reading state and responding with data.
    // Queries are read-only and handled outside the reducer intentionally:
    // they only snapshot existing state and terminal layout without side
    // effects, so routing through TCA actions would add ceremony without
    // improving testability or correctness.
    terminalManager.onQuery = { resource, params, clientFD in
      let repos = store.repositories.repositories
      let selectedWorktreeID = store.repositories.selectedWorktreeID
      let pctSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
      switch resource {
      case "repos":
        let data = repos.map {
          ["id": $0.id.addingPercentEncoding(withAllowedCharacters: pctSet) ?? $0.id]
        }
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
      case "worktrees":
        let data = repos.flatMap { repo in
          repo.worktrees.map { worktree in
            let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: pctSet) ?? worktree.id
            var entry = ["id": encodedID]
            if worktree.id == selectedWorktreeID { entry["focused"] = "1" }
            return entry
          }
        }
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
      case "tabs":
        guard let worktreeID = params["worktreeID"] else {
          AgentHookSocketServer.sendCommandResponse(
            clientFD: clientFD, ok: false, error: "Missing worktreeID for tab list.")
          return
        }
        let tabs = terminalManager.listTabs(worktreeID: worktreeID)
        if tabs == nil {
          // The worktree may exist in repo state but have no terminal yet.
          let decoded = worktreeID.removingPercentEncoding ?? worktreeID
          let worktreeExists = repos.contains { $0.worktrees.contains { $0.id == decoded } }
          guard worktreeExists else {
            AgentHookSocketServer.sendCommandResponse(
              clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
            return
          }
        }
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: tabs ?? [])
      case "surfaces":
        guard let worktreeID = params["worktreeID"], let tabID = params["tabID"] else {
          AgentHookSocketServer.sendCommandResponse(
            clientFD: clientFD, ok: false, error: "Missing worktreeID/tabID for surface list.")
          return
        }
        guard let surfaces = terminalManager.listSurfaces(worktreeID: worktreeID, tabID: tabID) else {
          AgentHookSocketServer.sendCommandResponse(
            clientFD: clientFD, ok: false, error: "Worktree or tab not found.")
          return
        }
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: surfaces)
      default:
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Unknown resource: \(resource)")
      }
    }
    appDelegate.persistence = persistence
  }

  private static func bootstrapSessionPersistence(
    persistence: SessionPersistence,
    scrollbackLimit: Int?
  ) {
    // For "Unlimited" (nil), cap at 1_000_000 — tmux's `history-limit 0` means
    // NO scrollback, and unbounded growth risks memory bloat in long sessions.
    let effectiveLimit = scrollbackLimit ?? 1_000_000
    do {
      try TmuxConfigWriter(paths: persistence.paths)
        .writeIfChanged(
          scrollbackLimit: effectiveLimit,
          userShell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
    } catch {
      SupaLogger("Sessions").warning("Failed to write tmux.conf at launch: \(error)")
    }

    // Propagate the (possibly updated) config to any tmux server that survived
    // from a previous app version. No-op when no server is running — the next
    // `new-session` call will read the file fresh anyway. Detached so it doesn't
    // block app startup. Window-scope options on already-created windows
    // (e.g. their exact `history-limit`) are not affected — only new windows
    // see those.
    Task.detached { [persistence] in
      await persistence.reloadTmuxConfig()
    }
  }

  private static func showAboutPanel() {
    let info = Bundle.main.infoDictionary ?? [:]
    let marketing = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    #if DEBUG
      let configuration = "Debug"
    #else
      let configuration = "Release"
    #endif
    NSApplication.shared.orderFrontStandardAboutPanel(options: [
      .applicationVersion: "\(marketing) (\(build)) \(configuration)",
      .version: "",
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  var body: some Scene {
    Window("CherryLily", id: WindowID.main) {
      GhosttyColorSchemeSyncView(ghostty: ghostty) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
      }
      .preferredColorScheme(store.settings.appearanceMode.colorScheme)
      .onChange(of: store.settings.showShortcutHints) { _, newValue in
        commandKeyObserver.isEnabled = newValue
      }
      .openSettingsOnSelection(store: store)
      .openDeeplinkReferenceOnRequest(store: store)
    }
    .handlesExternalEvents(matching: [])
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .commands {
      WorktreeCommands(store: store)
      SidebarCommands()
      TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
      WindowCommands(ghosttyShortcuts: ghosttyShortcuts)
      Group {
        CommandGroup(replacing: .appInfo) {
          Button("About CherryLily") {
            Self.showAboutPanel()
          }
        }
        CommandGroup(replacing: .appSettings) {
          SettingsMenuButton(shortcutOverrides: store.settings.shortcutOverrides) {
            store.send(.settings(.setSelection(.general)))
          }
        }
        CommandGroup(replacing: .help) {
          DeeplinkReferenceMenuButton()
        }
        CommandGroup(replacing: .appTermination) {
          Button("Quit CherryLily") {
            store.send(.requestQuit)
          }
          .keyboardShortcut("q")
          .help("Quit CherryLily (⌘Q)")
        }
      }
      CommandGroup(after: .textEditing) {
        let cmdPalette = AppShortcuts.commandPalette.effective(from: store.settings.shortcutOverrides)
        Button("Command Palette") {
          store.send(.commandPalette(.togglePresented))
        }
        .appKeyboardShortcut(cmdPalette)
        .help("Command Palette (\(cmdPalette?.display ?? "none"))")
      }
      UpdateCommands(store: store.scope(state: \.updates, action: \.updates))
      Group {
        CommandGroup(replacing: .windowList) {}
        CommandGroup(replacing: .singleWindowList) {
          Button("CherryLily") {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
              window.makeKeyAndOrderFront(nil)
              NSApp.activate(ignoringOtherApps: true)
            }
          }
          .keyboardShortcut("0")
          .help("Show main window (⌘0)")
        }
      }
    }
    Window("Settings", id: WindowID.settings) {
      SettingsView(store: store)
        .environment(ghosttyShortcuts)
        .environment(commandKeyObserver)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(store.settings.appearanceMode.colorScheme, for: .windowToolbar)
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 800, height: 600)
    .restorationBehavior(.disabled)
    Window("Deeplink Reference", id: WindowID.deeplinkReference) {
      DeeplinkReferenceView()
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
    Window("CLI Reference", id: WindowID.cliReference) {
      CLIReferenceView()
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
  }
}
