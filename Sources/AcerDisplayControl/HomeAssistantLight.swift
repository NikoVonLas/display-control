import Foundation
import Security

struct LightSensorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class SensorSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct SensorTokenCache {
    private var saved: (account: String, token: String)?

    mutating func remember(_ token: String, for account: String) {
        saved = (account, token)
    }

    mutating func token(for account: String, load: () throws -> String) rethrows -> String {
        if let saved, saved.account == account { return saved.token }
        let token = try load()
        remember(token, for: account)
        return token
    }
}

enum HomeAssistantLight {
    static func serverURL(_ server: String) throws -> URL {
        guard var parts = URLComponents(string: server), ["https", "http"].contains(parts.scheme?.lowercased()),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw LightSensorError("Проверьте адрес Home Assistant.") }
        parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw LightSensorError("Некорректный URL") }
        return url
    }

    static func endpoint(server: String, entity: String, lamp: Bool = false) throws -> URL {
        let domain = lamp ? "light" : "sensor"
        guard entity.range(of: "^\(domain)\\.[a-z0-9_]+$", options: .regularExpression) != nil else {
            throw LightSensorError("Введите ID сущности \(domain).…")
        }
        return try serverURL(server).appendingPathComponent("api/states").appendingPathComponent(entity)
    }

    static func account(for url: URL) -> String {
        "\(url.scheme!)://\(url.host!):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    private static func key(for url: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.nikovonlas.acer-display-control.ha",
         kSecAttrAccount as String: account(for: url)]
    }

    static func saveToken(_ token: String, for url: URL) throws {
        let query = key(for: url)
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                     kSecAttrLabel as String: "Display Control · Home Assistant"]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            let entry = query.merging(values) { _, new in new }
            result = SecItemAdd(entry as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw LightSensorError("Не удалось сохранить токен в Связке ключей") }
    }

    // The login keychain uses the file-based Security backend. Suppress its UI for
    // the entire synchronous lookup and restore the interaction policy on exit.
    @MainActor static func loadToken(for url: URL, interactive: Bool) throws -> String {
        var previous = DarwinBoolean(false)
        if !interactive {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw LightSensorError("Не удалось прочитать Связку ключей в фоне")
            }
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var query = key(for: url)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound {
            throw LightSensorError("Для этого сервера нужен токен Home Assistant")
        }
        guard result == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LightSensorError("Для доступа к сохранённому токену откройте настройки Home Assistant и нажмите «Подключить».")
        }
        return token
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: SensorSessionDelegate(), delegateQueue: nil)

    static func read(_ source: LightSource, server: String, token: String) async throws -> Reading {
        let url = try endpoint(server: server, entity: source.entity, lamp: source.isLamp)
        return try source.reading(from: await fetch(url, token: token))
    }

    private static func fetch(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LightSensorError("Home Assistant: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return payload
    }

    struct Entity: Decodable, Identifiable {
        struct Attributes: Decodable {
            let friendly_name: String?
            let unit_of_measurement: String?
        }
        let entity_id: String
        let attributes: Attributes
        var id: String { entity_id }
        var title: String { attributes.friendly_name ?? entity_id }
    }

    static func entities(server: URL, token: String, lamp: Bool) async throws -> [Entity] {
        let url = server.appendingPathComponent("api/states")
        let data = try await fetch(url, token: token)
        return try JSONDecoder().decode([Entity].self, from: data).filter {
            $0.id.hasPrefix(lamp ? "light." : "sensor.")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    struct Reading {
        let lux: Double
        let changedAt: Date?
        var name: String? = nil
        var rawValue: Double? = nil
        var unit: String? = nil
    }

    // Subscribe to the configured entities only. After acknowledgment and each event, read
    // its latest state so reconnects and bursts converge on the current value.
    static func observe(_ server: URL, entities: [String], token: String, changed: @MainActor (String?) -> Void) async throws {
        let api = server.appendingPathComponent("api/websocket")
        guard var parts = URLComponents(url: api, resolvingAgainstBaseURL: false) else {
            throw LightSensorError("Некорректный URL Home Assistant")
        }
        parts.scheme = server.scheme?.lowercased() == "https" ? "wss" : "ws"
        guard let endpoint = parts.url else { throw LightSensorError("Некорректный URL WebSocket") }
        let session = URLSession(configuration: .ephemeral, delegate: SensorSessionDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint)
        defer { session.invalidateAndCancel() }
        func receive() async throws -> [String: Any] {
            let data: Data
            switch try await socket.receive() {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: throw LightSensorError("Неизвестное сообщение Home Assistant")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LightSensorError("Некорректный ответ Home Assistant")
            }
            return json
        }
        func send(_ json: [String: Any]) async throws {
            let payload = try JSONSerialization.data(withJSONObject: json)
            try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        }
        try await withTaskCancellationHandler {
            socket.resume()
            guard try await receive()["type"] as? String == "auth_required" else { throw LightSensorError("Ошибка подключения HA") }
            try await send(["type": "auth", "access_token": token])
            guard try await receive()["type"] as? String == "auth_ok" else { throw LightSensorError("HA отклонил токен") }
            try await send(["id": 1, "type": "subscribe_trigger", "trigger": ["platform": "state", "entity_id": entities]])
            let result = try await receive()
            guard result["type"] as? String == "result", result["success"] as? Bool == true else {
                throw LightSensorError("HA отклонил подписку на датчик")
            }
            await changed(nil)
            while !Task.isCancelled {
                let message = try await receive()
                if message["id"] as? Int == 1, message["type"] as? String == "event" {
                    let event = message["event"] as? [String: Any]
                    let variables = event?["variables"] as? [String: Any]
                    let trigger = variables?["trigger"] as? [String: Any]
                    await changed(trigger?["entity_id"] as? String)
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    static func parse(_ data: Data, conversion: LuxConversion = .standard, isLamp: Bool = false, expectedUnit: String? = nil) throws -> Reading {
        struct State: Decodable {
            struct Attributes: Decodable {
                var unit_of_measurement: String?
                var friendly_name: String?
                var brightness: Double?
                var color_mode: String?
            }
            var last_changed: String?
            var last_updated: String?
            var state: String
            var attributes: Attributes
        }
        let item = try JSONDecoder().decode(State.self, from: data)
        let time = timestamp(isLamp ? item.last_updated : item.last_changed)
        let input: Double
        let unit = isLamp ? "%" : item.attributes.unit_of_measurement
        if isLamp {
            if item.state == "off" { return .init(lux: 0, changedAt: time, name: item.attributes.friendly_name, rawValue: 0, unit: "%") }
            guard item.state == "on", let value = item.attributes.brightness ?? (item.attributes.color_mode == "onoff" ? 255 : nil),
                  (0...255).contains(value) else { throw LightSensorError("Лампа не передала яркость.") }
            input = value * 100 / 255
        } else {
            guard let value = Double(item.state) else { throw LightSensorError("Нет числового показания.") }
            if let expectedUnit, expectedUnit != unit {
                throw LightSensorError("Единица в HA — \(unit ?? "без единицы"). Проверьте шкалу для \(expectedUnit).")
            }
            input = value
        }
        let lux = try conversion.lux(for: input, unit: unit)
        return Reading(lux: lux, changedAt: time, name: item.attributes.friendly_name, rawValue: input, unit: unit)
    }

    static func timestamp(_ value: String?) -> Date? {
        value.flatMap { text in
            (try? Date(text, strategy: .iso8601.time(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
        }
    }
}
