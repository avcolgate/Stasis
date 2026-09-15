import Defaults
import SwiftUI

struct GeneralSettingsView: View {
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.batteryPercentageDisplayLocation) var batteryPercentageDisplayLocation
    @Default(.showBatteryStateInStatusIcon) var showBatteryStateInStatusIcon
    @Default(.disableNotifications) var disableNotifications
    @Default(.showChargingStatusChangedNotification) var showChargingStatusChangedNotification

    @State private var notificationResult: String?
    @State private var testingNotification = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section {
                Picker("Show percentage", selection: $batteryPercentageDisplayLocation) {
                    Text("Hidden").tag(PercentageDisplayLocation.hidden)
                    Text("Next to icon").tag(PercentageDisplayLocation.nextToIcon)
                    Text("Inside icon").tag(PercentageDisplayLocation.insideIcon)
                }
                Toggle("Show battery state", isOn: $showBatteryStateInStatusIcon)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu Bar Icon")
                    Text(
                        "Display battery percentage next to or inside the menu bar icon."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Disable all notifications", isOn: $disableNotifications)
                Toggle("Charging status changed", isOn: $showChargingStatusChangedNotification)
                    .disabled(disableNotifications)
                Button("Send Test Notification") {
                    testingNotification = true
                    Task {
                        do {
                            try await ChargingNotificationService.shared.sendTestNotification()
                            notificationResult = "Test sent. Check Notification Center if no banner appears."
                        } catch {
                            notificationResult = error.localizedDescription
                        }
                        testingNotification = false
                    }
                }
                .disabled(disableNotifications || testingNotification)
                if let notificationResult {
                    Text(notificationResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                    Text("Control when Stasis sends you notifications.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .onChange(of: launchAtLogin) { _, newValue in
            LaunchAtLoginService.shared.setLaunchAtLogin(newValue)
        }
    }
}

#Preview {
    GeneralSettingsView()
}
