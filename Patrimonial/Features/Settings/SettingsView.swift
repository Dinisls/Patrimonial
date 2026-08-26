import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"
    @AppStorage("appTheme") private var appTheme = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "settings_general")) {
                    Picker(String(localized: "settings_currency"), selection: $defaultCurrency) {
                        Text("EUR (€)").tag("EUR")
                        Text("USD ($)").tag("USD")
                        Text("GBP (£)").tag("GBP")
                    }

                    Picker(String(localized: "settings_theme"), selection: $appTheme) {
                        Text(String(localized: "settings_theme_system")).tag("system")
                        Text(String(localized: "settings_theme_light")).tag("light")
                        Text(String(localized: "settings_theme_dark")).tag("dark")
                    }
                }

                Section(String(localized: "settings_about")) {
                    LabeledContent(String(localized: "settings_version"), value: "1.0.0")
                    LabeledContent(String(localized: "settings_developer"), value: "Dinis Santos")
                }
            }
            .navigationTitle(String(localized: "settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "form_done")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
