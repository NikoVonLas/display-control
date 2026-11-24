import SwiftUI

private enum SourceEditor: Identifiable {
    case server
    case source(LightSource, lamp: Bool)

    var id: String {
        switch self {
        case .server: "server"
        case .source(let source, _): source.id.uuidString
        }
    }
}

struct SensorPreferences: View {
    @ObservedObject var store: DisplayStore
    @State private var editor: SourceEditor?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.sensorHost.isEmpty {
                HStack {
                    Text("Источники").font(.headline)
                    Spacer()
                    Button { add(lamp: false) } label: { Label("Добавить датчик", systemImage: "plus") }
                    Button { add(lamp: true) } label: { Label("Добавить лампу", systemImage: "plus") }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !store.sources.isEmpty {
                            GroupBox {
                                VStack(spacing: 0) {
                                    ForEach(store.sources) { source in
                                        if source.id != store.sources.first?.id { Divider() }
                                        sourceRow(source)
                                    }
                                }.padding(.horizontal, 8)
                            }
                        } else {
                            Text("Нет подключённых источников.").foregroundStyle(.secondary)
                        }
                        if !store.lighting.useSensor {
                            Text("Автояркость по освещённости выключена.").font(.caption).foregroundStyle(.secondary)
                        } else if !store.sensorStatus.isEmpty {
                            Label(store.sensorStatus, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                        } else if let id = store.winningEntity, let changed = store.sourceStatus[id]?.reading?.changedAt {
                            Text("Показание в Home Assistant изменилось \(changed.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if store.lighting.useSensor, store.sources.isEmpty, let lux = store.lighting.lux {
                Text("Внешний замер · \(luxText(lux))").foregroundStyle(.secondary)
            }
            serverConnection
            if store.sensorHost.isEmpty { Spacer() }
        }
        .padding(18)
        .sheet(item: $editor) { selection in
            switch selection {
            case .server: ServerEditor(store: store)
            case let .source(source, lamp): LightSourceEditor(store: store, source: source, lamp: lamp)
            }
        }
    }

    private var serverConnection: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Home Assistant").font(.headline)
                    if !store.sensorHost.isEmpty {
                        Text(verbatim: store.sensorHost)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(store.sensorHost)
                    }
                }
                Spacer(minLength: 4)
                Button(store.sensorHost.isEmpty ? "Подключить" : "Настроить подключение") {
                    editor = .server
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }
            .padding(6)
        }
    }

    private func add(lamp: Bool) {
        editor = .source(.init(entity: "", conversion: lamp ? .points([]) : .standard), lamp: lamp)
    }

    private func luxText(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)))) лк"
    }

    private func sourceRow(_ source: LightSource) -> some View {
        let status = store.sourceStatus[source.entity]
        let winner = store.winningEntity == source.entity
        let caption = source.isLamp ? "Оценка от лампы" : "Замер датчика"
        return HStack(spacing: 10) {
            Image(systemName: source.isLamp ? "lightbulb" : "sun.max")
                .font(.title3).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(status?.name ?? source.entity).fontWeight(.medium).lineLimit(2)
                Text(status?.error ?? (winner ? "\(caption) · для автояркости" : caption))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(status?.reading.map { (source.isLamp ? "≈ " : "") + luxText($0.lux) } ?? "—")
                .monospacedDigit().fixedSize()
            Button { editor = .source(source, lamp: source.isLamp) } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Настроить \(status?.name ?? source.entity)")
                .help("Настроить источник")
        }.padding(.vertical, 10)
    }
}

private struct ServerEditor: View {
    @ObservedObject var store: DisplayStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var token = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Home Assistant").font(.title2.weight(.semibold))
            LabeledContent("Адрес") { TextField("https://home.example", text: $host) }
            LabeledContent("Токен") {
                SecureField(host == store.sensorHost && !host.isEmpty ? "Из Связки ключей" : "Токен доступа", text: $token)
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Подключить") {
                    do {
                        try store.configureServer(host: host.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
                        token = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 410).onAppear { host = store.sensorHost }
    }
}

private struct LightSourceEditor: View {
    @ObservedObject var store: DisplayStore
    let source: LightSource
    let lamp: Bool
    @Environment(\.dismiss) private var dismiss
    private enum Mode { case standard, points, color }
    private struct Row: Identifiable {
        let id = UUID()
        var input = ""
        var lux = ""
    }
    @State private var entity = ""
    @State private var mode = Mode.standard
    @State private var rows: [Row] = []
    @State private var warm = ""
    @State private var cool = ""
    @State private var inputUnit = ""
    @State private var error = ""
    @State private var choosing = false
    private var existing: Bool { store.sources.contains { $0.id == source.id } }

    private func format(_ n: Double) -> String {
        n.formatted(.number.grouping(.never).precision(.significantDigits(1...17)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lamp ? "Лампа" : "Датчик освещённости").font(.title2.weight(.semibold))
            LabeledContent("ID в Home Assistant") {
                TextField(lamp ? "light.desk" : "sensor.desk", text: $entity)
                Button("Выбрать") { choosing = true }
                    .popover(isPresented: $choosing) {
                        EntityChooser(store: store, lamp: lamp, sourceID: source.id) { item in
                            entity = item.id
                            inputUnit = item.attributes.unit_of_measurement ?? ""
                            choosing = false
                        }
                    }
            }
            if let reading = store.sourceStatus[source.entity]?.reading, let raw = reading.rawValue {
                Text("Показание · \(raw.formatted()) \(reading.unit ?? "")").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Пересчёт в люксы", selection: $mode) {
                if lamp { Text("По цвету и яркости").tag(Mode.color) }
                else { Text("По единице датчика").tag(Mode.standard) }
                Text("По своим точкам").tag(Mode.points)
            }
            switch mode {
            case .standard:
                Text("Поддерживаются люксы, килолюксы и фут-канделы. Для другой шкалы задайте свои точки.")
                    .font(.caption).foregroundStyle(.secondary)
            case .color:
                Text("Освещённость при 100% яркости").font(.headline)
                HStack(spacing: 14) {
                    LabeledContent("Тёплый") { TextField("лк", text: $warm) }
                    LabeledContent("Холодный") { TextField("лк", text: $cool) }
                    Text("лк")
                }
            case .points:
                if !lamp {
                    LabeledContent("Единица датчика") {
                        TextField("Например, % или В", text: $inputUnit)
                            .help("Можно оставить пустым для показаний без фиксированной единицы.")
                    }
                }
                HStack {
                    Text(lamp ? "Яркость лампы, %" : "Значение датчика").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Освещённость, лк").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 18)
                }.font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach($rows) { $row in
                            HStack {
                                TextField(lamp ? "Яркость, %" : "Показание", text: $row.input)
                                TextField("Люксы", text: $row.lux)
                                Button { [id = row.id] in rows.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Удалить точку")
                            }
                        }
                    }
                }.frame(height: min(100, CGFloat(rows.count) * 27))
                Button { rows.append(Row()) } label: { Label("Добавить точку", systemImage: "plus") }.buttonStyle(.borderless)
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if existing {
                    Button("Удалить источник") {
                        do { try store.removeSource(source.id); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Сохранить" : "Добавить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear {
            entity = source.entity
            inputUnit = source.inputUnit ?? store.sourceStatus[source.entity]?.reading?.unit ?? ""
            switch source.conversion {
            case .standard: mode = .standard
            case .points(let points):
                mode = .points
                rows = points.map { Row(input: format($0.input), lux: format($0.lux)) }
            case let .color(w, c):
                mode = .color
                warm = format(w)
                cool = format(c)
            }
            if rows.isEmpty { rows = [Row(input: "0", lux: "0"), Row(input: lamp ? "100" : "", lux: "")] }
        }
    }

    private func save() {
        func number(_ text: String) throws -> Double {
            guard let n = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), n.isFinite else {
                throw LightSensorError("Заполните все числовые поля.")
            }
            return n
        }
        do {
            var updated = source
            updated.entity = entity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard updated.entity.hasPrefix(lamp ? "light." : "sensor.") else {
                throw LightSensorError(lamp ? "ID лампы начинается с light." : "ID датчика начинается с sensor.")
            }
            switch mode {
            case .standard: updated.conversion = .standard
            case .color: updated.conversion = .color(warm: try number(warm), cool: try number(cool))
            case .points: updated.conversion = .points(try rows.map { .init(input: try number($0.input), lux: try number($0.lux)) })
            }
            let unit = inputUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.inputUnit = !lamp && mode == .points && !unit.isEmpty ? unit : nil
            try store.saveSource(updated)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct EntityChooser: View {
    @ObservedObject var store: DisplayStore
    let lamp: Bool
    let sourceID: UUID
    let select: (HomeAssistantLight.Entity) -> Void
    @State private var query = ""
    @State private var entities: [HomeAssistantLight.Entity]?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Найти по имени или ID", text: $query)
            if let entities {
                let used = Set(store.sources.filter { $0.id != sourceID }.map(\.entity))
                let matches = entities.filter { !used.contains($0.id) && (query.isEmpty ||
                    $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)) }
                if matches.isEmpty { Text("Нет подходящих источников").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { item in
                            Button { select(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text([item.id, item.attributes.unit_of_measurement].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }.padding(12).frame(width: 315, height: 235)
        .task {
            do { entities = try await store.availableEntities(lamp: lamp) }
            catch { self.error = error.localizedDescription }
        }
    }
}
