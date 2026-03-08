import ComposableArchitecture
import SwiftUI

struct AppLauncherSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section(
          header: Text("Built-in Integrations"),
          footer: Text("Toggle which built-in tools appear in the launcher menu.")
        ) {
          ForEach(OpenWorktreeAction.allPredefinedCases) { action in
            Toggle(isOn: bindingForAction(action.id)) {
              HStack(spacing: 6) {
                OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
                if !action.isInstalled {
                  Text("(Not installed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
            .disabled(!action.isInstalled)
          }
        }

        Section(
          header: Text("Custom Tools"),
          footer: Text("Add your own applications to the launcher menu.")
        ) {
          ForEach(store.state.customWorktreeActions) { action in
            HStack {
              if let iconData = action.icon, let image = NSImage(data: iconData) {
                Image(nsImage: image)
                  .resizable()
                  .frame(width: 16, height: 16)
              }
              Text(action.name)
              Spacer()
              Button(role: .destructive) {
                store.send(.removeCustomAction(action.id))
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.plain)
            }
          }

          Button {
            store.send(.addCustomApplicationButtonTapped)
          } label: {
            HStack {
              Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
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

  private func bindingForAction(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !store.disabledWorktreeActions.contains(id) },
      set: { isEnabled in
        var disabled = store.disabledWorktreeActions
        if isEnabled {
          disabled.remove(id)
        } else {
          disabled.insert(id)
        }
        store.disabledWorktreeActions = disabled
      }
    )
  }
}
