import SwiftUI

struct KeyboardView: View {
  @Environment(SettingsStore.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    Form {
      Section("Keyboard") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Swap Option and Command", isOn: $settings.swapOptionCommand)
          Text(
            "Windows Win/Alt keys map to Mac Option/Command in swapped positions (for keyboards laid out Ctrl-Win-Alt)."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .navigationTitle("Keyboard")
  }
}
