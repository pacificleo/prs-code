import ComposableArchitecture
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases(settings: store.state.globalSettings)
    Form {
      Section {
        LabeledContent("Appearance") {
          HStack(spacing: 12) {
            let appearanceMode = $store.appearanceMode
            ForEach(AppearanceMode.allCases) { mode in
              AppearanceOptionCardView(
                mode: mode,
                isSelected: mode == appearanceMode.wrappedValue,
                action: { appearanceMode.wrappedValue = mode }
              )
            }
          }
        }
        Toggle(isOn: $store.terminalThemeSyncEnabled) {
          Text("Sync with Terminal")
          Text("Applies the appearance-aware CherryLily color palette.")
        }
        if !store.terminalThemeSyncEnabled {
          VStack(alignment: .leading, spacing: 4) {
            Text("Add a theme to `~/.config/ghostty/config`")
            Text("e.g. `theme = light:Monokai Pro Light Sun,dark:Dimmed Monokai`")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        }
      }
      Section {
        Toggle(
          "Confirm before Quitting",
          isOn: $store.confirmBeforeQuit
        )
        .help("Ask before quitting CherryLily")
        Toggle(
          "Confirm before closing terminal tabs",
          isOn: $store.confirmBeforeClosingTabs
        )
        .help("Show a confirmation dialog when closing a tab")
      }
      Section("Keyboard") {
        Toggle(
          "Show shortcut hints when holding Command or Control",
          isOn: $store.showShortcutHints
        )
        .help("Show keyboard shortcut hints on worktree rows, tabs, and buttons when holding modifier keys")
      }
      Section("Editor") {
        Picker(
          selection: $store.defaultEditorID
        ) {
          Text("Automatic")
            .tag(OpenWorktreeAction.automaticSettingsID)
          ForEach(openActionOptions) { action in
            Text(action.labelTitle)
              .tag(action.settingsID)
          }
        } label: {
          Text("Default Editor")
          Text("Applies to Worktrees without repository overrides.")
        }
      }
      Section("Advanced") {
        Toggle(isOn: $store.hideSingleTabBar) {
          Text("Hide Tab Bar for Single Tab")
          Text("Automatically hides the tab bar when only one tab is open.")
        }
        Toggle(isOn: $store.allowArbitraryDeeplinkInput) {
          Text("Allow Arbitrary Deeplink Actions")
          Text("Skip the confirmation dialog when a deeplink runs a command or performs a destructive action.")
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)

    .navigationTitle("General")
  }
}
