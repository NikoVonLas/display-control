import AppKit
import DisplayCore
import SwiftUI

struct ControlPanel: View {
    @ObservedObject var store: DisplayStore
    let openPreferences: () -> Void

    private var selectedHost: String? {
        guard let input = store.currentInput, let hub = store.currentHubRoute else { return nil }
        if input == .usbC && hub == .usbC { return "mac" }
        if input == .displayPort && hub == .usbB { return "pc" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.display?.productName ?? "Acer Display Control")
                        .font(.system(size: 15, weight: .semibold))
                    Text(connection).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless).accessibilityLabel("Обновить состояние")
                .help("Обновить состояние").disabled(store.isBusy)
            }
            .padding(.horizontal, 18).padding(.top, 15)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Яркость", systemImage: "sun.max").font(.headline)
                    Spacer()
                    Text(store.brightnessPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                Slider(value: Binding(get: { store.brightnessPercent ?? 0 }, set: { store.setBrightness($0.rounded()) }),
                       in: (store.currentInput == .usbC ? -90.0 : 0)...100)
                    .controlSize(.large).accessibilityLabel("Яркость подсветки")
                    .disabled(!store.brightnessAvailable || store.isBusy)
                if let value = store.brightnessPercent, value < 0 {
                    Text("Программное затемнение").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background { PanelField(shape: RoundedRectangle(cornerRadius: 18)) }
            .padding(.horizontal, 10).padding(.vertical, 8)

            HStack(spacing: 4) {
                hostButton("Этот Mac", symbol: "laptopcomputer", selected: selectedHost == "mac",
                           action: store.applyMacProfile)
                hostButton("Второй PC", symbol: "pc", selected: selectedHost == "pc",
                           action: store.applyPCProfile)
                    .disabled(!store.hubConfiguration.isEnabled)
            }
            .padding(3)
            .background { PanelField(shape: Capsule()) }
            .disabled(store.isBusy)
            .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 8) {
                portRow("Видеовход") {
                    Picker("Видеовход", selection: Binding(get: { store.currentInput }, set: { input in
                        if let input { store.setInput(input) }
                    })) {
                        ForEach([VideoInput.usbC, .displayPort, .hdmi1, .hdmi2]) { input in
                            Text(input.shortTitle).tag(Optional(input))
                        }
                    }
                }
                portRow("USB-хаб") {
                    Picker("USB-хаб", selection: Binding(get: { store.currentHubRoute }, set: { route in
                        if let route { store.setHubRoute(route) }
                    })) {
                        ForEach(HubRoute.allCases) { route in
                            Text(route.title).tag(Optional(route))
                        }
                    }.disabled(!store.hubConfiguration.isEnabled)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isBusy)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background { PanelField(shape: RoundedRectangle(cornerRadius: 18)) }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)

            if let notice = store.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
            HStack {
                Button {
                    openPreferences()
                } label: { Label("Настройки", systemImage: "gearshape") }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .frame(width: 356)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuPanelSurface())

    }

    private var connection: String {
        if store.display == nil { return "Поиск монитора…" }
        if store.isBusy { return "Применяем настройки…" }
        return store.isDisplayDisconnected ? "Отключён от рабочего стола Mac" : "Подключён к Mac"
    }

    private func hostButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).fontWeight(selected ? .semibold : .regular)
                if selected { Image(systemName: "checkmark").font(.caption.bold()) }
            }
            .frame(maxWidth: .infinity, minHeight: 31)
            .background {
                if selected {
                    Capsule().fill(.secondary.opacity(0.2))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func portRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            control().labelsHidden().frame(maxWidth: .infinity)
        }
    }
}

private struct PanelField<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape.fill(.primary.opacity(0.035))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.primary.opacity(0.23), .primary.opacity(0.07), .primary.opacity(0.17)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            }
    }
}

private struct MenuPanelSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .circular)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
