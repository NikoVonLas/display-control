import SwiftUI

struct GeneralPreferences: View {
    @ObservedObject var store: DisplayStore
    @ObservedObject var loginItem: LoginItemStore
    @ObservedObject var keys: BrightnessKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesSection("Приложение") {
                Toggle("Запускать при входе", isOn: Binding(get: { loginItem.isRequested }, set: loginItem.setEnabled))
                if loginItem.requiresApproval {
                    Button("Подтвердить в объектах входа…") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.errorMessage { Text(error).foregroundStyle(.secondary) }
                Toggle("Отключать Acer как экран Mac при переходе на PC",
                       isOn: Binding(get: { store.disconnectDisplayForPC }, set: store.setDisconnectDisplayForPC))
                    .disabled(store.isBusy)
            }
            PreferencesSection("Клавиши яркости") {
                HStack {
                    Text("Универсальный доступ")
                    Spacer(minLength: 12)
                    Text(keys.state == .accessRequired ? "Требуется разрешение" : "Разрешён")
                        .foregroundStyle(.secondary)
                }
                switch keys.state {
                case .active:
                    EmptyView()
                case .accessRequired:
                    if keys.accessRequestPending {
                        Text("Запрос отправлен в macOS").foregroundStyle(.secondary)
                        Text("Если вы закрыли запрос, откройте настройки приложения заново, чтобы повторить его.")
                            .font(.caption)
                    } else {
                        Button("Запросить доступ…") { keys.requestAccess() }
                    }
                case .unavailable:
                    Text("Обработчик клавиш пока недоступен.")
                    Button("Проверить снова") { keys.startIfPermitted() }
                }
            }
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh(); keys.startIfPermitted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            keys.startIfPermitted()
        }
    }
}
