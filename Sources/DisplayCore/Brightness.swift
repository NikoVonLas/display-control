import Foundation

public struct Brightness: Equatable, Sendable {
    public let current: UInt16
    public let maximum: UInt16

    public init(snapshot: VCPFeatureSnapshot) throws {
        guard snapshot.code == 0x10, snapshot.maximum > 0,
              snapshot.current <= snapshot.maximum else {
            throw DisplayControlError.hardware(code: -10, description: "Монитор вернул некорректную яркость")
        }
        current = snapshot.current
        maximum = snapshot.maximum
    }

    public var percent: Double { Double(current) / Double(maximum) * 100 }

    public func rawValue(percent: Double) throws -> UInt16 {
        guard percent.isFinite, (0...100).contains(percent) else {
            throw DisplayControlError.invalidNumber(String(percent))
        }
        return UInt16((percent / 100 * Double(maximum)).rounded())
    }
}

public extension DisplayControlling {
    func brightness(displayUUID: String) throws -> Brightness {
        try Brightness(snapshot: read(featureCode: 0x10, displayUUID: displayUUID))
    }

    @discardableResult
    func setBrightness(percent: Double, displayUUID: String) throws -> Brightness {
        let before = try brightness(displayUUID: displayUUID)
        let value = try before.rawValue(percent: percent)
        try write(featureCode: 0x10, value: value, displayUUID: displayUUID)
        // Some picture modes acknowledge DDC writes but lock brightness.
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.1)
            let after = try brightness(displayUUID: displayUUID)
            if after.current == value { return after }
        }
        throw DisplayControlError.hardware(
            code: -11,
            description: "Монитор не применил яркость. Проверьте HDR и режим изображения в меню монитора."
        )
    }
}
