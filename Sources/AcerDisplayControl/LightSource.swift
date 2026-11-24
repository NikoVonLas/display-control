import Foundation

struct LuxPoint: Codable, Equatable {
    let input: Double
    let lux: Double
}

enum LuxConversion: Codable, Equatable {
    case standard
    case points([LuxPoint])
    case color(warm: Double, cool: Double)

    func validated(isLamp: Bool) throws -> Self {
        switch self {
        case .standard:
            guard !isLamp else { throw LightSensorError("Для лампы задайте оценку в люксах.") }
        case let .color(warm, cool):
            guard isLamp, warm.isFinite, cool.isFinite, warm > 0, cool > 0 else {
                throw LightSensorError("Введите положительные люксы для обоих оттенков белого.")
            }
        case let .points(points):
            guard !points.isEmpty else { throw LightSensorError("Добавьте хотя бы одну точку.") }
            guard points.allSatisfy({ $0.input.isFinite && $0.lux.isFinite && $0.lux >= 0 }) else {
                throw LightSensorError("Проверьте числа в таблице. Освещённость должна быть от 0 лк.")
            }
            guard !isLamp || points.allSatisfy({ (0...100).contains($0.input) }) else {
                throw LightSensorError("Яркость лампы должна быть от 0 до 100%.")
            }
            guard Set(points.map(\.input)).count == points.count else {
                throw LightSensorError("Укажите разные входные значения.")
            }
            return .points(points.sorted { $0.input < $1.input })
        }
        return self
    }

    func lux(for input: Double, unit: String?) throws -> Double {
        guard input.isFinite else { throw LightSensorError("Источник не передал число.") }
        switch self {
        case .standard:
            let factor: Double
            switch unit?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "lx", "lux", "лк": factor = 1
            case "klx", "килолюкс", "клк": factor = 1000
            case "fc", "ft-c", "foot-candle", "foot-candles": factor = 1 / (0.3048 * 0.3048)
            default: throw LightSensorError("Для этой единицы выберите пересчёт по точкам.")
            }
            let lux = input * factor
            guard lux.isFinite, lux >= 0 else { throw LightSensorError("Некорректная освещённость.") }
            return lux
        case let .points(points):
            guard var lower = points.first else { throw LightSensorError("Добавьте точки пересчёта.") }
            if input <= lower.input { return lower.lux }
            for upper in points.dropFirst() {
                if input <= upper.input {
                    if input == upper.input { return upper.lux }
                    let fraction = (input - lower.input) / (upper.input - lower.input)
                    return lower.lux + fraction * (upper.lux - lower.lux)
                }
                lower = upper
            }
            return lower.lux
        case .color: throw LightSensorError("Для расчёта нужен цвет лампы.")
        }
    }
}

struct LightSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var entity: String
    var conversion: LuxConversion
    var inputUnit: String?
    var isLamp: Bool { entity.hasPrefix("light.") }

    func reading(from data: Data) throws -> HomeAssistantLight.Reading {
        if case let .color(warm, cool) = conversion {
            return try LampCalibration(entity: entity, warmLux: warm, coolLux: cool).estimate(data)
        }
        return try HomeAssistantLight.parse(data, conversion: conversion, isLamp: isLamp, expectedUnit: inputUnit)
    }

    static let storageKey = "haLightSources.v1"

    static func load(from defaults: UserDefaults) -> [Self] {
        if let data = defaults.data(forKey: storageKey) {
            return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
        }
        var sources: [Self] = []
        if let entity = defaults.string(forKey: "haSensor"), !entity.isEmpty {
            sources.append(.init(entity: entity, conversion: .standard))
        }
        if let data = defaults.data(forKey: "haLampCalibration"),
           let lamp = try? JSONDecoder().decode(LampCalibration.self, from: data) {
            sources.append(.init(entity: lamp.entity, conversion: .color(warm: lamp.warmLux, cool: lamp.coolLux)))
        }
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: storageKey) }
        return sources
    }
}
