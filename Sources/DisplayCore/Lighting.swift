import Foundation

public struct Lighting: Codable, Equatable, Sendable {
    public struct SensorPoint: Codable, Equatable, Sendable {
        public let lux: Double
        public let brightness: Double

        public init(lux: Double, brightness: Double) {
            self.lux = lux
            self.brightness = brightness
        }
    }

    public enum Schedule: String, Codable, CaseIterable, Sendable { case off, clock, sun }
    public var schedule = Schedule.off
    public var dawn = 8
    public var dusk = 21
    public var latitude: Double?
    public var longitude: Double?
    public var day = 100.0
    public var night = 35.0
    // Optional storage preserves settings saved before BenQ calibration existed.
    private var benqMinimumPercent: Double?
    public var benqMinimum: Double {
        get { min(100, max(1, benqMinimumPercent ?? 50)) }
        set { benqMinimumPercent = min(100, max(1, newValue)) }
    }

    public func benqSoftwareShade(at level: Double, hardwareBrightness: Double) -> Double {
        guard hardwareBrightness > 0 else { return 0 }
        let fraction = min(1, max(0, level) / hardwareBrightness)
        return (1 - benqMinimum / 100) * (1 - fraction)
    }
    public var syncBenQ = false
    public var useSensor = false
    public private(set) var sensorPoints = [SensorPoint(lux: 0, brightness: 35), SensorPoint(lux: 500, brightness: 100)]
    public var lux: Double?
    public var luxDate: Date?
    public var pauseUntil: Date?
    public init() {}

    private enum LegacyKeys: String, CodingKey { case sensorDarkLux, zeroBrightnessLux, sensorBrightLux }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try values.decode(Schedule.self, forKey: .schedule)
        dawn = try values.decode(Int.self, forKey: .dawn)
        dusk = try values.decode(Int.self, forKey: .dusk)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        day = try values.decode(Double.self, forKey: .day)
        night = try values.decode(Double.self, forKey: .night)
        benqMinimumPercent = try values.decodeIfPresent(Double.self, forKey: .benqMinimumPercent)
        syncBenQ = try values.decode(Bool.self, forKey: .syncBenQ)
        useSensor = try values.decode(Bool.self, forKey: .useSensor)
        lux = try values.decodeIfPresent(Double.self, forKey: .lux)
        luxDate = try values.decodeIfPresent(Date.self, forKey: .luxDate)
        pauseUntil = try values.decodeIfPresent(Date.self, forKey: .pauseUntil)

        if let points = try values.decodeIfPresent([SensorPoint].self, forKey: .sensorPoints) {
            guard setSensorPoints(points) else {
                throw DecodingError.dataCorruptedError(forKey: .sensorPoints, in: values, debugDescription: "Invalid sensor points")
            }
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let dark = try legacy.decodeIfPresent(Double.self, forKey: .sensorDarkLux) ?? 0
            let bright = try legacy.decodeIfPresent(Double.self, forKey: .sensorBrightLux) ?? 500
            sensorPoints = [SensorPoint(lux: dark, brightness: night)]
            if night < 0, let zero = try legacy.decodeIfPresent(Double.self, forKey: .zeroBrightnessLux),
               dark < zero, zero < bright {
                sensorPoints.append(SensorPoint(lux: zero, brightness: 0))
            }
            sensorPoints.append(SensorPoint(lux: bright, brightness: day))
        }
    }

    public mutating func setSensorPoints(_ points: [SensorPoint]) -> Bool {
        guard points.allSatisfy({ $0.lux.isFinite && $0.lux >= 0 && (-90...100).contains($0.brightness) }),
              Set(points.map(\.lux)).count == points.count else { return false }
        sensorPoints = points.sorted { $0.lux < $1.lux }
        return true
    }

    public func isPaused(at date: Date) -> Bool { pauseUntil.map { $0 > date } ?? false }

    // Fraction of daytime lighting. A clock transition takes 45 minutes.
    // For solar control, interpolate from civil twilight to the low daytime sun.
    public func daylight(at date: Date, calendar: Calendar = .current) -> Double {
        if schedule == .sun, let latitude, let longitude {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let ordinal = utc.ordinality(of: .day, in: .year, for: date) ?? 1
            let hour = Double(utc.component(.hour, from: date)) + Double(utc.component(.minute, from: date)) / 60
            let phase = 2 * Double.pi / 365 * (Double(ordinal - 1) + (hour - 12) / 24)
            let equation = 229.18 * (0.000075 + 0.001868*cos(phase) - 0.032077*sin(phase)
                                      - 0.014615*cos(2*phase) - 0.040849*sin(2*phase))
            let dec = 0.006918 - 0.399912*cos(phase) + 0.070257*sin(phase)
                - 0.006758*cos(2*phase) + 0.000907*sin(2*phase)
                - 0.002697*cos(3*phase) + 0.00148*sin(3*phase)
            let lat = latitude * .pi / 180
            let angle = (hour*15 + equation/4 + longitude - 180) * .pi / 180
            let elevation = asin(min(1, max(-1, sin(lat)*sin(dec) + cos(lat)*cos(dec)*cos(angle)))) * 180 / .pi
            return min(1, max(0, (elevation + 6) / 12))
        }
        let minute = calendar.component(.hour, from: date)*60 + calendar.component(.minute, from: date)
        let sinceDawn = (minute - dawn*60 + 1440) % 1440
        let dayLength = ((dusk - dawn + 24) % 24)*60
        if sinceDawn < dayLength { return min(1, Double(sinceDawn)/45) }
        return max(0, 1 - Double(sinceDawn - dayLength)/45)
    }

    public func target(at date: Date) -> Double? {
        guard !isPaused(at: date) else { return nil }
        let scheduled = schedule == .off ? nil : night + (day - night) * daylight(at: date)
        if useSensor, let lux, let luxDate, (0..<300).contains(date.timeIntervalSince(luxDate)),
           let level = sensorLevel(lux: lux) {
            return min(scheduled ?? level, level).rounded()
        }
        return scheduled?.rounded()
    }

    private func sensorLevel(lux: Double) -> Double? {
        guard var lower = sensorPoints.first else { return nil }
        if lux <= lower.lux { return lower.brightness }
        for upper in sensorPoints.dropFirst() {
            if lux <= upper.lux {
                if lux == upper.lux { return upper.brightness }
                // log(1 + lux) interpolation, retaining precision for nearby readings.
                let fraction = log1p((lux - lower.lux) / (1 + lower.lux))
                    / log1p((upper.lux - lower.lux) / (1 + lower.lux))
                return lower.brightness + fraction * (upper.brightness - lower.brightness)
            }
            lower = upper
        }
        return lower.brightness
    }
}
