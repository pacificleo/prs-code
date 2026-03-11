import ComposableArchitecture
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases(settings: store.state.globalSettings)
    VStack(alignment: .leading) {
      Form {
        Section("Appearance") {
          HStack {
            let appearanceMode = $store.appearanceMode
            ForEach(AppearanceMode.allCases) { mode in
              AppearanceOptionCardView(
                mode: mode,
                isSelected: mode == appearanceMode.wrappedValue
              ) {
                appearanceMode.wrappedValue = mode
              }
            }
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Terminal theming follows Ghostty config")
            Text("For example, add the following line to `~/.config/ghostty/config`")
            Text("theme = light:Monokai Pro Light Sun,dark:Dimmed Monokai")
              .monospaced()
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        }
        Section("Default Editor") {
          Picker(
            "Default editor",
            selection: $store.defaultEditorID
          ) {
            Text("Automatic")
              .tag(OpenWorktreeAction.automaticSettingsID)
            ForEach(openActionOptions) { action in
              Text(action.labelTitle)
                .tag(action.settingsID)
            }
          }
          .help("Applies to worktrees without repository overrides.")
        }
        Section("Keyboard") {
          Toggle(
            "Show shortcut hints when holding Command or Control",
            isOn: $store.showShortcutHints
          )
          .help("Show keyboard shortcut hints on worktree rows, tabs, and buttons when holding modifier keys")
        }
        Section("Quit") {
          Toggle(
            "Confirm before quitting",
            isOn: $store.confirmBeforeQuit
          )
          .help("Ask before quitting CherryLily")
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
