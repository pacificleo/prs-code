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
  var appStore: StoreOf<AppFeature>?
  var terminalManager: WorktreeTerminalManager?
  var persistence: SessionPersistence?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false
    ])
    appStore?.send(.appLaunched)
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

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard let persistence, let terminalManager else { return }
    @Shared(.settingsFile) var settings
    guard settings.global.restoreSessionsOnLaunch else { return }

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
      _ = await persistence.captureAll(for: layout)
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(2))
  }

  private func mainWindow(from sender: NSApplication) -> NSWindow? {
    if let window = sender.windows.first(where: { $0.identifier?.rawValue == "main" }) {
      return window
    }
    if let window = sender.windows.first(where: { $0.identifier?.rawValue != "settings" }) {
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
    let persistence = SessionPersistence(paths: SessionPaths())
    let terminalManager = WorktreeTerminalManager(
      runtime: runtime,
      persistenceEnabled: {
        @Shared(.settingsFile) var settingsFile
        return settingsFile.global.restoreSessionsOnLaunch
      },
      persistence: persistence,
    )
    if initialSettings.restoreSessionsOnLaunch {
      Self.bootstrapSessionPersistence(persistence: persistence)
    }
    _terminalManager = State(initialValue: terminalManager)
    terminalManager.loadLayoutOnLaunch()
    if initialSettings.restoreSessionsOnLaunch, let layout = terminalManager.loadedLayout {
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
    appDelegate.persistence = persistence
    SettingsWindowManager.shared.configure(
      store: appStore,
      ghosttyShortcuts: shortcuts,
      commandKeyObserver: keyObserver
    )
  }

  private static func bootstrapSessionPersistence(persistence: SessionPersistence) {
    do {
      try TmuxConfigWriter(paths: persistence.paths)
        .writeIfChanged(
          scrollbackLimit: 50_000,
          userShell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
    } catch {
      SupaLogger("Sessions").warning("Failed to write tmux.conf at launch: \(error)")
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
    Window("CherryLily", id: "main") {
      GhosttyColorSchemeSyncView(ghostty: ghostty) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
      }
      .preferredColorScheme(store.settings.appearanceMode.colorScheme)
      .onChange(of: store.settings.showShortcutHints) { _, newValue in
        commandKeyObserver.isEnabled = newValue
      }
    }
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .commands {
      WorktreeCommands(store: store)
      SidebarCommands()
      TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
      WindowCommands(ghosttyShortcuts: ghosttyShortcuts)
      CommandGroup(replacing: .appInfo) {
        Button("About CherryLily") {
          Self.showAboutPanel()
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
      CommandGroup(replacing: .windowArrangement) {
        Button("CherryLily") {
          if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
          }
        }
        .keyboardShortcut("0")
        .help("Show main window (⌘0)")
        Divider()
        Button("Minimize") {
          NSApp.keyWindow?.miniaturize(nil)
        }
        .keyboardShortcut("m")
        .help("Minimize (⌘M)")
        Button("Zoom") {
          NSApp.keyWindow?.zoom(nil)
        }
        .help("Zoom (no shortcut)")
      }
      CommandGroup(replacing: .appSettings) {
        let settings = AppShortcuts.openSettings.effective(from: store.settings.shortcutOverrides)
        Button("Settings...") {
          SettingsWindowManager.shared.show()
        }
        .appKeyboardShortcut(settings)
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit CherryLily") {
          store.send(.requestQuit)
        }
        .keyboardShortcut("q")
        .help("Quit CherryLily (⌘Q)")
      }
    }
  }
}
