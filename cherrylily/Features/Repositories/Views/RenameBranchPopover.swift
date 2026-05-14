import SwiftUI

struct RenameBranchPopover: View {
  @Binding var draftName: String
  let onCancel: () -> Void
  let onSubmit: (String) -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Branch")
        .font(.headline)

      TextField("Branch name", text: $draftName)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onChange(of: draftName) { _, newValue in
          let filtered = String(newValue.filter { !$0.isWhitespace })
          if filtered != newValue {
            draftName = filtered
          }
        }
        .onSubmit { submit() }
        .onExitCommand { onCancel() }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .frame(width: 280)
    .task { isFocused = true }
  }

  private func submit() {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
  }
}
