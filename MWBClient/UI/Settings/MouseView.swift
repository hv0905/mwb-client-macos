import SwiftUI

struct MouseView: View {
  @Environment(SettingsStore.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    Form {
      Section("Mouse") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Move mouse relatively", isOn: $settings.moveMouseRelatively)
          Text(
            "Use this option when remote machine's monitor settings are different, or remote machine has multiple monitors"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Block mouse at screen corners", isOn: $settings.blockMouseAtCorners)
          Text("To avoid accident machine-switch at screen corners")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Hide mouse at screen edge", isOn: $settings.hideMouseAtScreenEdge)
          Text(
            "Hide the cursor at the top edge when switching to another machine, and take focus from full-screen apps to ensure keyboard input is redirected"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Disable Easy Mouse when an application is running in full screen",
            isOn: $settings.disableEasyMouseInFullscreen)
          Text(
            "Prevent Easy Mouse from moving to another machine when an application is in full-screen mode"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Invert remote scroll wheel", isOn: $settings.invertRemoteScroll)
          Text(
            "Only affects scrolling injected from the Windows machine; your Mac's own mouse and trackpad are unaffected."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Scroll wheel multiplier")
            Spacer()
            Text("\(settings.scrollMultiplier, format: .number.precision(.fractionLength(2)))×")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Slider(value: $settings.scrollMultiplier, in: 0.25...4.0, step: 0.25)
          Text(
            "Scales how far each scroll wheel event from the Windows machine scrolls. Does not affect your Mac's own mouse and trackpad scrolling."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .navigationTitle("Mouse")
  }
}
