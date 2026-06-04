import AppKit
import ComposableArchitecture
import SwiftUI

struct AppLauncherSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section(
          header: Text("Toolbar Apps"),
          footer: Text(
            "Pinned apps appear as icons in the worktree toolbar, in this order. "
              + "Newly installed apps may require a restart to appear."
          )
        ) {
          if store.state.pinnedToolbarActions.isEmpty {
            Text("No apps pinned. Pin apps below to show them in the toolbar.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(Array(store.state.pinnedToolbarActions.enumerated()), id: \.element) { index, id in
            HStack(spacing: 8) {
              if let action = resolveAction(id: id) {
                OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
              } else {
                Text(id)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                store.send(.movePinnedToolbarAction(from: IndexSet(integer: index), toOffset: index - 1))
              } label: {
                Image(systemName: "chevron.up")
                  .accessibilityLabel("Move up")
              }
              .buttonStyle(.borderless)
              .disabled(index == 0)
              .help("Move up")

              Button {
                store.send(.movePinnedToolbarAction(from: IndexSet(integer: index), toOffset: index + 2))
              } label: {
                Image(systemName: "chevron.down")
                  .accessibilityLabel("Move down")
              }
              .buttonStyle(.borderless)
              .disabled(index == store.state.pinnedToolbarActions.count - 1)
              .help("Move down")

              Button(role: .destructive) {
                store.send(.setToolbarPin(id: id, pinned: false))
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
                  .accessibilityLabel("Remove from toolbar")
              }
              .buttonStyle(.plain)
              .help("Remove from toolbar")
            }
          }
        }

        Section(
          header: Text("Available Apps"),
          footer: Text("Toggle which installed apps are pinned to the toolbar.")
        ) {
          ForEach(unpinnedBuiltIns) { action in
            Toggle(isOn: pinBinding(for: action.settingsID)) {
              OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
            }
          }
        }

        Section(
          header: Text("Custom Tools"),
          footer: Text("Add your own applications, then pin them to the toolbar.")
        ) {
          ForEach(store.state.customWorktreeActions) { action in
            HStack {
              if let iconData = action.icon, let image = NSImage(data: iconData) {
                Image(nsImage: image)
                  .resizable()
                  .frame(width: 16, height: 16)
                  .accessibilityHidden(true)
              }
              Text(action.name)
              Spacer()
              Toggle("", isOn: pinBinding(for: action.id))
                .labelsHidden()
                .help("Pin to toolbar")
              Button(role: .destructive) {
                store.send(.removeCustomAction(action.id))
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
                  .accessibilityLabel("Remove application")
              }
              .buttonStyle(.plain)
              .help("Remove application")
            }
          }

          Button {
            store.send(.addCustomApplicationButtonTapped)
          } label: {
            HStack {
              Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
              Text("Add Application")
            }
          }
          .buttonStyle(.plain)
          .padding(.top, 4)
        }
      }
      .formStyle(.grouped)
    }
  }

  private var unpinnedBuiltIns: [OpenWorktreeAction] {
    let pinned = Set(store.state.pinnedToolbarActions)
    return OpenWorktreeAction.menuOrder.filter { $0.isInstalled && !pinned.contains($0.settingsID) }
  }

  private func resolveAction(id: String) -> OpenWorktreeAction? {
    if let builtIn = OpenWorktreeAction.menuOrder.first(where: { $0.settingsID == id }) {
      return builtIn
    }
    if let custom = store.state.customWorktreeActions.first(where: { $0.id == id }) {
      return OpenWorktreeAction(
        bundleIdentifier: "custom",
        title: custom.name,
        settingsID: custom.id,
        customIconData: custom.icon
      )
    }
    return nil
  }

  private func pinBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { store.state.pinnedToolbarActions.contains(id) },
      set: { store.send(.setToolbarPin(id: id, pinned: $0)) }
    )
  }
}
