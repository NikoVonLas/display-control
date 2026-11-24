import AppKit
import SwiftUI

@main
struct AcerDisplayControlApp: App {
    @NSApplicationDelegateAdaptor(MenuApplicationDelegate.self) private var delegate
    @StateObject private var loginItemStore = LoginItemStore()

    private enum PreferencesTab: String, CaseIterable {
        case lighting = "Освещение"
        case sensors = "Датчики"
        case advanced = "Расширенные"

#if ACER_UPDATES
        case updates = "Обновления"
#endif

        var symbol: String {
            switch self {
            case .lighting: "sun.horizon"
            case .sensors: "sensor"
            case .advanced: "gearshape.2"
#if ACER_UPDATES
            case .updates: "arrow.triangle.2.circlepath"
#endif
            }
        }
    }

    @State private var tab = PreferencesTab.lighting

    var body: some Scene { launchInMenuBar(preferences) }

    // SceneBuilder cannot express an availability check with an else branch.
    private func launchInMenuBar(_ scene: some Scene) -> some Scene {
        if #available(macOS 15, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(scene.defaultLaunchBehavior(.suppressed)))
        }
        return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(scene))
    }

    private var preferences: some Scene {
        Settings {
            HStack(spacing: 0) {
                Color.clear.frame(width: 170).overlay {
                    List(PreferencesTab.allCases, id: \.self, selection: $tab) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                    .listStyle(.sidebar)
                    .accessibilityLabel("Разделы настроек")
                }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.rawValue)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 20).padding(.top, 16)
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            LightingPreferences(store: delegate.store)
                        }
                        .modifier(SettingsPage(visible: tab == .lighting))
                        SensorPreferences(store: delegate.store)
                            .modifier(SettingsPage(visible: tab == .sensors))
                        ScrollView {
                            GeneralPreferences(store: delegate.store, loginItem: loginItemStore, keys: delegate.store.brightnessKeys)
                        }
                        .modifier(SettingsPage(visible: tab == .advanced))
#if ACER_UPDATES
                        AppUpdateSettings(controller: delegate.updates)
                            .modifier(SettingsPage(visible: tab == .updates))
#endif
                    }
                }
                .frame(width: 510, alignment: .leading)
            }
            .frame(width: 681, height: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            .onDisappear { delegate.store.brightnessKeys.endSettingsSession() }
        }
        .windowResizability(.contentSize)
    }
}

private struct SettingsPage: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}
