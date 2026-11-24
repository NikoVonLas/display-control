import SwiftUI
import DisplayCore

struct LightingPreferences: View {
    @ObservedObject var store: DisplayStore
    @State private var error = ""
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesSection("Автояркость") {
                Toggle(isOn: $store.lighting.useSensor) {
                    Text("Учитывать освещённость").frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch)
                Picker("Расписание яркости", selection: $store.lighting.schedule) {
                    Text("Выкл.").tag(Lighting.Schedule.off)
                    Text("По часам").tag(Lighting.Schedule.clock)
                    Text("По солнцу").tag(Lighting.Schedule.sun)
                }
                if store.lighting.schedule == .sun {
                    HStack {
                        TextField("Широта", text: $latitude)
                        TextField("Долгота", text: $longitude)
                        Button("Сохранить") {
                            guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
                                  let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
                                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                                error = "Широта от −90 до 90°, долгота от −180 до 180°"; return
                            }
                            store.lighting.latitude = lat
                            store.lighting.longitude = lon
                            error = ""
                        }
                    }
                    if store.lighting.latitude == nil { Text("До ввода координат используется расписание по часам.").font(.caption) }
                }
                if store.lighting.schedule == .clock {
                    Stepper("Утро с \(store.lighting.dawn):00", value: $store.lighting.dawn, in: 0...23)
                    Stepper("Вечер с \(store.lighting.dusk):00", value: $store.lighting.dusk, in: 0...23)
                }
                if store.lighting.schedule != .off {
                    level("Днём", Binding(get: { store.lighting.day }, set: {
                        store.lighting.day = $0
                        store.lighting.night = min(store.lighting.night, $0)
                    }), 0...100)
                    level("Ночью", $store.lighting.night, -90...store.lighting.day)
                }
                if let until = store.lighting.pauseUntil, until > Date() {
                    HStack {
                        Text("Ручная яркость до \(until.formatted(date: .omitted, time: .shortened))")
                        Button("Вернуться в авто") { store.lighting.pauseUntil = nil }
                    }
                }
            }

            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if store.lighting.useSensor {
                SensorCalibrationPreferences(lighting: $store.lighting)
            }

            PreferencesSection("Экраны Mac") {
                Toggle("Синхронизировать яркость двух мониторов", isOn: $store.lighting.syncBenQ)
                if store.lighting.syncBenQ {
                    level("Второй монитор при 0% Acer", $store.lighting.benqMinimum, 1...100)
                    Text("При программном затемнении это доля яркости, выставленной в меню второго монитора. Ниже нуля оба экрана затемняются дальше.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            NightShiftPreferences()
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            latitude = store.lighting.latitude.map { String($0) } ?? ""
            longitude = store.lighting.longitude.map { String($0) } ?? ""
        }
    }

    private func level(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(label) {
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
            Text("\(Int(value.wrappedValue))%").monospacedDigit().frame(width: 48)
        }
    }
}

private struct SensorCalibrationPreferences: View {
    @Binding var lighting: Lighting
    private struct Row: Identifiable {
        let id = UUID()
        var lux = ""
        var brightness = ""

        init() {}

        init(_ point: Lighting.SensorPoint) {
            let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.significantDigits(1...17))
            lux = point.lux.formatted(format)
            brightness = point.brightness.formatted(format)
        }
    }

    @State private var rows: [Row] = []
    @State private var error = ""
    @FocusState private var focusedLux: UUID?

    var body: some View {
        PreferencesSection("Яркость по освещённости") {
            if rows.isEmpty {
                Text("Добавьте точку, чтобы датчик управлял яркостью.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Освещённость, лк")
                        Text("Яркость, %")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach($rows) { $row in
                        GridRow {
                            TextField("Освещённость, лк", text: $row.lux)
                                .focused($focusedLux, equals: row.id)
                            TextField("Яркость, %", text: $row.brightness)
                            Button { [id = row.id] in
                                rows.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Удалить точку")
                            .help("Удалить точку")
                        }
                    }
                }
            }
            HStack {
                Button {
                    let row = Row()
                    rows.append(row)
                    focusedLux = row.id
                } label: { Label("Добавить точку", systemImage: "plus") }
                Spacer()
                Button("Сохранить", action: save)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear { rows = lighting.sensorPoints.map(Row.init) }
    }

    private func save() {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        var points: [Lighting.SensorPoint] = []
        for (index, row) in rows.enumerated() {
            guard let lux = number(row.lux), lux.isFinite, lux >= 0 else {
                error = "Строка \(index + 1). Введите освещённость от 0 лк."
                return
            }
            guard let brightness = number(row.brightness), (-90...100).contains(brightness) else {
                error = "Строка \(index + 1). Введите яркость от −90 до 100%."
                return
            }
            points.append(.init(lux: lux, brightness: brightness))
        }
        var updated = lighting
        guard updated.setSensorPoints(points) else {
            error = "У каждой точки должно быть своё значение освещённости."
            return
        }
        lighting = updated
        rows = updated.sensorPoints.map(Row.init)
        error = ""
    }
}
