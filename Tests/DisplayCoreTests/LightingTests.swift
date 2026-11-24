import XCTest
import DisplayCore
@testable import AcerDisplayControl

final class LightingTests: XCTestCase {
    private let midday = Date(timeIntervalSince1970: 1_710_936_000) // March equinox, 12:00 UTC

    func testScheduleSensorPauseAndExpiry() {
        var settings = Lighting()
        XCTAssertNil(settings.target(at: midday))
        settings.schedule = .sun
        settings.latitude = 0
        settings.longitude = 0
        XCTAssertEqual(settings.target(at: midday), 100)
        XCTAssertEqual(settings.target(at: midday.addingTimeInterval(43200)), 35)
        settings.useSensor = true
        settings.lux = 0
        settings.luxDate = midday
        XCTAssertEqual(settings.target(at: midday), 35)
        XCTAssertEqual(settings.target(at: midday.addingTimeInterval(301)), 100)
        settings.pauseUntil = midday.addingTimeInterval(120)
        XCTAssertNil(settings.target(at: midday))
        XCTAssertEqual(settings.target(at: midday.addingTimeInterval(121)), 35)
    }

    func testBenQCalibrationAndLegacySettings() throws {
        let legacy = Data(#"{"schedule":"clock","dawn":7,"dusk":20,"day":85,"night":10,"warmth":40,"syncBenQ":true,"useSensor":false}"#.utf8)
        var settings = try JSONDecoder().decode(Lighting.self, from: legacy)
        XCTAssertEqual(settings.schedule, .clock)
        XCTAssertTrue(settings.syncBenQ)
        XCTAssertEqual(settings.benqSoftwareShade(at: 0, hardwareBrightness: 90), 0.5)
        settings.benqMinimum = 70
        settings = try JSONDecoder().decode(Lighting.self, from: JSONEncoder().encode(settings))
        for (level, shade) in [(-90.0, 0.3), (0, 0.3), (45, 0.15), (90, 0), (100, 0)] {
            XCTAssertEqual(settings.benqSoftwareShade(at: level, hardwareBrightness: 90), shade, accuracy: 0.0001)
        }
        XCTAssertEqual(settings.benqSoftwareShade(at: 0, hardwareBrightness: 0), 0)
    }

    func testCalibratedSensorCrossesHardwareMinimumAtMeasuredLux() throws {
        let legacy = Data(#"{"schedule":"off","dawn":8,"dusk":21,"day":100,"night":-25,"useSensor":true,"syncBenQ":true,"sensorDarkLux":0.5,"zeroBrightnessLux":1.57,"sensorBrightLux":500}"#.utf8)
        var settings = try JSONDecoder().decode(Lighting.self, from: legacy)
        XCTAssertEqual(settings.sensorPoints, [.init(lux: 0.5, brightness: -25), .init(lux: 1.57, brightness: 0), .init(lux: 500, brightness: 100)])
        settings.luxDate = midday
        settings = try JSONDecoder().decode(Lighting.self, from: JSONEncoder().encode(settings))
        for (lux, expected) in [(0.0, -25.0), (0.3, -25), (0.5, -25), (0.51125, -25),
                                (1, -12), (1.56565, 0), (1.57, 0), (10, 28), (500, 100), (800, 100)] {
            settings.lux = lux
            XCTAssertEqual(settings.target(at: midday), expected)
        }
    }

    func testArbitraryCurveIsIndependentOfScheduleAndCanBeCleared() throws {
        var settings = Lighting()
        settings.useSensor = true
        settings.luxDate = midday
        settings.day = 20
        settings.night = 5
        let points: [Lighting.SensorPoint] = [.init(lux: 30, brightness: 80), .init(lux: 1, brightness: -20),
                                              .init(lux: 10, brightness: 40), .init(lux: 15, brightness: 25)]
        XCTAssertTrue(settings.setSensorPoints(points))
        XCTAssertFalse(settings.setSensorPoints([points[0], points[0]]))
        XCTAssertFalse(settings.setSensorPoints([.init(lux: -1, brightness: 0)]))
        XCTAssertFalse(settings.setSensorPoints([.init(lux: 1, brightness: 101)]))
        XCTAssertEqual(settings.sensorPoints.map(\.lux), [1, 10, 15, 30])
        for (lux, expected) in [(0.0, -20.0), (10, 40), (12, 33), (15, 25), (100, 80)] {
            settings.lux = lux
            XCTAssertEqual(settings.target(at: midday), expected)
        }
        settings.schedule = .sun
        settings.latitude = 0
        settings.longitude = 0
        XCTAssertEqual(settings.target(at: midday), 20)
        settings.schedule = .off
        XCTAssertTrue(settings.setSensorPoints([points[0]]))
        settings.lux = 0
        XCTAssertEqual(settings.target(at: midday), 80)
        XCTAssertTrue(settings.setSensorPoints([]))
        settings = try JSONDecoder().decode(Lighting.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(settings.target(at: midday))
    }

    func testClockTransitionAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var settings = Lighting()
        settings.dawn = 22
        settings.dusk = 4
        let sample = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22, minute: 15))!
        XCTAssertEqual(settings.daylight(at: sample, calendar: calendar), 1.0/3, accuracy: 0.0001)
        XCTAssertEqual(settings.daylight(at: sample.addingTimeInterval(3*3600), calendar: calendar), 1)
        XCTAssertEqual(settings.daylight(at: sample.addingTimeInterval(8*3600), calendar: calendar), 0)
    }

    func testSensorTokenCacheReadsOnceAndSeparatesServers() throws {
        var cache = SensorTokenCache()
        var reads = 0
        func load() -> String { reads += 1; return "sample" }
        XCTAssertEqual(cache.token(for: "a", load: load), "sample")
        XCTAssertEqual(cache.token(for: "a", load: load), "sample")
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try cache.token(for: "b") { throw LightSensorError("locked") })
        XCTAssertEqual(cache.token(for: "b", load: load), "sample")
        cache.remember("replacement", for: "b")
        XCTAssertEqual(cache.token(for: "b", load: load), "replacement")
        XCTAssertEqual(reads, 2)
    }

    func testHomeAssistantLuxValidation() throws {
        let url = try HomeAssistantLight.endpoint(server: "https://ha.example.invalid/", entity: "sensor.office_lux")
        XCTAssertEqual(url.absoluteString, "https://ha.example.invalid/api/states/sensor.office_lux")
        XCTAssertThrowsError(try HomeAssistantLight.endpoint(server: "https://ha.example.invalid", entity: "../config"))
        func sample(_ value: String, _ unit: String) -> Data {
            Data(#"{"state":"\#(value)","attributes":{"unit_of_measurement":"\#(unit)"}}"#.utf8)
        }
        XCTAssertEqual(try HomeAssistantLight.parse(sample("12.5", "lx")).lux, 12.5)
        for value in ["unavailable", "nan", "-1"] {
            XCTAssertThrowsError(try HomeAssistantLight.parse(sample(value, "lx")))
        }
        XCTAssertThrowsError(try HomeAssistantLight.parse(sample("20", "°C")))
    }

    func testCustomSourceScaleAndIlluminanceUnits() throws {
        XCTAssertEqual(try LuxConversion.standard.lux(for: 2, unit: "klx"), 2000)
        XCTAssertEqual(try LuxConversion.standard.lux(for: 1, unit: "fc"), 10.76391, accuracy: 0.00001)
        let points = [LuxPoint(input: 100, lux: 0), .init(input: 50, lux: 25), .init(input: 0, lux: 100)]
        let scale = try LuxConversion.points(points).validated(isLamp: false)
        XCTAssertEqual(try scale.lux(for: -1, unit: nil), 100)
        XCTAssertEqual(try scale.lux(for: 75, unit: "%"), 12.5)
        XCTAssertEqual(try scale.lux(for: 256, unit: "ADC"), 0)
        XCTAssertThrowsError(try LuxConversion.points([points[0], points[0]]).validated(isLamp: false))
        let light = LightSource(entity: "light.desk", conversion: scale)
        let on = Data(#"{"state":"on","attributes":{"brightness":51}}"#.utf8)
        XCTAssertEqual(try light.reading(from: on).lux, 70)
        XCTAssertEqual(try light.reading(from: Data(#"{"state":"off","attributes":{}}"#.utf8)).lux, 0)
    }

    func testLampEstimateUsesBrightnessAndActiveColorMode() throws {
        let lamp = LampCalibration(entity: "light.desk", warmLux: 160, coolLux: 200)
        func estimate(_ state: String, _ attrs: [String: Any]) throws -> Double {
            let payload = try JSONSerialization.data(withJSONObject: ["state": state, "attributes": attrs])
            return try lamp.estimate(payload).lux
        }
        let white: [String: Any] = ["color_mode": "color_temp", "color_temp_kelvin": 4600,
                                    "min_color_temp_kelvin": 2700, "max_color_temp_kelvin": 6500,
                                    "brightness": 128, "rgb_color": [255, 181, 100]]
        XCTAssertEqual(try estimate("on", white), 180 * 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(try estimate("off", [:]), 0)
        XCTAssertThrowsError(try estimate("unavailable", [:]))
        XCTAssertEqual(try estimate("on", ["color_mode": "xy", "rgb_color": [255, 0, 0], "brightness": 255]), 42.52, accuracy: 0.001)
        XCTAssertThrowsError(try estimate("on", ["brightness": 255, "color_mode": "hs"]))
    }
}
