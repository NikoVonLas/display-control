#if ACER_UPDATES
import Sparkle
import SwiftUI

struct AppUpdateSettings: View {
    let controller: SPUStandardUpdaterController
    @State private var checks = false
    @State private var downloads = false
    @State private var canCheck = false

    var body: some View {
        Form {
            Section {
                Toggle("Автоматически проверять обновления", isOn: Binding(
                    get: { checks }, set: { controller.updater.automaticallyChecksForUpdates = $0 }))
                Toggle("Автоматически устанавливать обновления", isOn: Binding(
                    get: { downloads }, set: { controller.updater.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!checks)
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Button("Проверить обновления") { controller.checkForUpdates(nil) }
                    .disabled(!canCheck)
            }
        }
        .formStyle(.grouped)
        .onReceive(controller.updater.publisher(for: \.automaticallyChecksForUpdates)) { checks = $0 }
        .onReceive(controller.updater.publisher(for: \.automaticallyDownloadsUpdates)) { downloads = $0 }
        .onReceive(controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
#endif
