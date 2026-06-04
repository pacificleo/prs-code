import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import CherryLily

@MainActor
struct SettingsFeaturePinTests {
  @Test(.dependencies) func setToolbarPinAddsAndRemoves() async {
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }

    await store.send(.setToolbarPin(id: "cursor", pinned: true)) {
      $0.pinnedToolbarActions = ["finder", "editor", "cursor"]
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.setToolbarPin(id: "finder", pinned: false)) {
      $0.pinnedToolbarActions = ["editor", "cursor"]
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func moveReorders() async {
    var settings = GlobalSettings.default
    settings.pinnedToolbarActions = ["finder", "editor", "cursor"]
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.movePinnedToolbarAction(from: IndexSet(integer: 2), toOffset: 0)) {
      $0.pinnedToolbarActions = ["cursor", "finder", "editor"]
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func removeCustomActionUnpins() async {
    var settings = GlobalSettings.default
    settings.customWorktreeActions = [
      CustomWorktreeAction(
        id: "custom.foo",
        name: "Foo",
        url: URL(filePath: "/Applications/Foo.app"),
        icon: nil
      ),
    ]
    settings.pinnedToolbarActions = ["finder", "custom.foo"]
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.removeCustomAction("custom.foo")) {
      $0.customWorktreeActions = []
      $0.pinnedToolbarActions = ["finder"]
    }
    await store.receive(\.delegate.settingsChanged)
  }
}
