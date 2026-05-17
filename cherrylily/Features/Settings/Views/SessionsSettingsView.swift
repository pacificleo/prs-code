import AppKit
import ComposableArchitecture
import SwiftUI

struct SessionsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var showClearConfirm = false

  // 5 choices for the scrollback picker; nil = Unlimited
  private static let scrollbackChoices: [(label: String, value: Int?)] = [
    ("10,000 lines", 10_000),
    ("50,000 lines", 50_000),
    ("100,000 lines", 100_000),
    ("500,000 lines", 500_000),
    ("Unlimited", nil),
  ]

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.restoreSessionsOnLaunch) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Restore terminal contents on launch")
            Text("Tabs, splits, working directories, and scrollback come back when you reopen CherryLily.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .help("When enabled, CherryLily saves your terminal state on quit and restores it on next launch.")

        Picker(selection: $store.sessionScrollbackLimit) {
          ForEach(Self.scrollbackChoices, id: \.label) { choice in
            Text(choice.label).tag(choice.value)
          }
        } label: {
          Text("Scrollback to keep per pane")
        }
        .pickerStyle(.menu)
        .help("How much history to capture for each pane on quit. Applies after relaunch.")
      }

      Section("Advanced") {
        Toggle(isOn: $store.hourlyAutosaveEnabled) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Save automatically every hour")
            Text("In case CherryLily exits unexpectedly.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .help("Periodically captures scrollback while CherryLily is running.")

        VStack(alignment: .leading, spacing: 8) {
          Text("Storage")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          HStack {
            Text(SessionPaths().root.path)
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Spacer()
          }
          HStack {
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([SessionPaths().root])
            }
            .help("Open the session storage folder in Finder.")

            Button(role: .destructive) {
              showClearConfirm = true
            } label: {
              Text("Clear saved sessions")
            }
            .help("Deletes the saved layout and scrollback files. Your current terminals stay open.")
          }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Clear saved sessions?",
      isPresented: $showClearConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        SessionDataClearer(paths: SessionPaths()).clearSavedData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This deletes the saved layout and scrollback files. "
        + "Your currently open tabs will keep running, but won't be restorable until next quit."
      )
    }
  }
}
