import AppKit
import CDDC
import SwiftUI

struct NightShiftPreferences: View {
    @State private var available = false
    @State private var enabled = false
    @State private var strength = 0.0
    @State private var error = ""

    var body: some View {
        PreferencesSection("Night Shift") {
            if available {
                Toggle("Включить Night Shift", isOn: Binding(get: { enabled }, set: { value in
                    if ADCNightShiftSetEnabled(value) {
                        enabled = value
                        error = ""
                    } else { reportFailure() }
                }))
                LabeledContent("Теплота") {
                    Slider(value: Binding(get: { strength }, set: { value in
                        let percent = value.rounded()
                        if ADCNightShiftSetStrength(Float(percent / 100)) {
                            strength = percent
                            error = ""
                        } else { reportFailure() }
                    }), in: 0...100)
                    Text("\(Int(strength.rounded()))%").monospacedDigit().frame(width: 48)
                }
            }
            Button("Расписание Night Shift в настройках дисплеев…") {
                if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) {
                    error = "Откройте Системные настройки → Дисплеи → Night Shift."
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: read)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in read() }
    }

    private func read() {
        var current = false
        var value: Float = 0
        available = ADCNightShiftRead(&current, &value)
        if available {
            enabled = current
            strength = Double(value) * 100
        }
    }

    private func reportFailure() {
        read()
        error = "macOS не применила изменение. Откройте Night Shift в настройках дисплеев."
    }
}
