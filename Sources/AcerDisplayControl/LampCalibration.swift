import Foundation

/// Estimated illuminance at the desk from the lamp alone, at full brightness.
struct LampCalibration: Codable, Equatable {
    let entity: String
    let warmLux: Double
    let coolLux: Double

    func estimate(_ payload: Data) throws -> HomeAssistantLight.Reading {
        struct Light: Decodable {
            struct Attributes: Decodable {
                let friendly_name: String?
                let brightness: Int?
                let color_mode: String?
                let color_temp_kelvin, min_color_temp_kelvin, max_color_temp_kelvin: Double?
                let rgb_color: [Double]?
            }
            let state: String
            let attributes: Attributes
            let last_updated: String?
        }
        let light = try JSONDecoder().decode(Light.self, from: payload)
        let time = HomeAssistantLight.timestamp(light.last_updated)
        if light.state == "off" { return .init(lux: 0, changedAt: time, name: light.attributes.friendly_name, rawValue: 0, unit: "%") }
        let a = light.attributes
        guard light.state == "on", let brightness = a.brightness ?? (a.color_mode == "onoff" ? 255 : nil), (0...255).contains(brightness) else {
            throw LightSensorError("Лампа не передала яркость")
        }

        let fullLux: Double
        switch a.color_mode {
        case "color_temp":
            guard let kelvin = a.color_temp_kelvin, let low = a.min_color_temp_kelvin,
                  let high = a.max_color_temp_kelvin, high > low else {
                throw LightSensorError("Лампа не передала цветовую температуру")
            }
            let mix = min(1, max(0, (kelvin - low) / (high - low)))
            fullLux = warmLux + mix * (coolLux - warmLux)
        case "xy", "hs", "rgb", "rgbw", "rgbww":
            guard let rgb = a.rgb_color, rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else {
                throw LightSensorError("Лампа не передала цвет")
            }
            // sRGB relative luminance approximates perceived light for colored settings.
            let channels = rgb.map { component in
                let c = component / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            fullLux = coolLux * (0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2])
        default:
            fullLux = warmLux
        }
        return .init(lux: fullLux * Double(brightness) / 255, changedAt: time, name: light.attributes.friendly_name, rawValue: Double(brightness) * 100 / 255, unit: "%")
    }
}
