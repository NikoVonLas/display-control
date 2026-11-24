import Foundation

public struct ExternalDisplay: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt32
    public let uuid: String
    public let productName: String
    public let manufacturer: String
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32

    public init(
        id: UInt32,
        uuid: String,
        productName: String,
        manufacturer: String,
        vendorID: UInt32,
        modelID: UInt32,
        serialNumber: UInt32
    ) {
        self.id = id
        self.uuid = uuid
        self.productName = productName
        self.manufacturer = manufacturer
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
    }

    public var isTargetAcer: Bool {
        manufacturer.caseInsensitiveCompare("ACR") == .orderedSame ||
            productName.localizedCaseInsensitiveContains("XV282K")
    }
}

public struct VCPFeatureSnapshot: Codable, Equatable, Sendable {
    public let code: UInt8
    public let type: UInt8
    public let maximum: UInt16
    public let current: UInt16

    public init(code: UInt8, type: UInt8, maximum: UInt16, current: UInt16) {
        self.code = code
        self.type = type
        self.maximum = maximum
        self.current = current
    }

    public var codeHex: String {
        String(format: "0x%02X", code)
    }
}

public enum VideoInput: UInt16, CaseIterable, Codable, Identifiable, Sendable {
    case displayPort = 0x0F
    case usbC = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12

    public var id: UInt16 { rawValue }

    public var title: String {
        switch self {
        case .usbC:
            return "USB‑C"
        case .displayPort:
            return "DisplayPort"
        case .hdmi1:
            return "HDMI 1"
        case .hdmi2:
            return "HDMI 2"
        }
    }

    public var shortTitle: String {
        self == .displayPort ? "DP" : title
    }

    public var symbolName: String {
        switch self {
        case .usbC:
            return "cable.connector"
        case .displayPort:
            return "display"
        case .hdmi1, .hdmi2:
            return "rectangle.portrait.and.arrow.forward"
        }
    }
}

public enum HubRoute: String, CaseIterable, Codable, Identifiable, Sendable {
    case usbC
    case usbB

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usbC:
            return "USB‑C"
        case .usbB:
            return "USB‑B"
        }
    }
}

public struct HubCommandConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var featureCode: UInt8
    public var usbCValue: UInt16
    public var usbBValue: UInt16

    public init(
        isEnabled: Bool = true,
        featureCode: UInt8 = 0xEA,
        usbCValue: UInt16 = 1,
        usbBValue: UInt16 = 0
    ) {
        self.isEnabled = isEnabled
        self.featureCode = featureCode
        self.usbCValue = usbCValue
        self.usbBValue = usbBValue
    }

    public static let xv282KPatchedFirmware = HubCommandConfiguration()

    public func value(for route: HubRoute) -> UInt16 {
        switch route {
        case .usbC:
            return usbCValue
        case .usbB:
            return usbBValue
        }
    }

    public func route(for value: UInt16) -> HubRoute? {
        if value == usbCValue {
            return .usbC
        }
        if value == usbBValue {
            return .usbB
        }
        return nil
    }
}

public struct VCPDifference: Codable, Equatable, Sendable {
    public let code: UInt8
    public let before: VCPFeatureSnapshot
    public let after: VCPFeatureSnapshot

    public init(code: UInt8, before: VCPFeatureSnapshot, after: VCPFeatureSnapshot) {
        self.code = code
        self.before = before
        self.after = after
    }
}

public enum DisplayControlError: LocalizedError, Equatable, Sendable {
    case noAcerDisplay
    case hardware(code: Int32, description: String)
    case invalidNumber(String)

    public var errorDescription: String? {
        switch self {
        case .noAcerDisplay:
            return "Acer XV282K KV не найден"
        case let .hardware(_, description):
            return description
        case let .invalidNumber(value):
            return "Некорректное число: \(value)"
        }
    }
}

public enum NumberParser {
    public static func uint16(_ text: String) throws -> UInt16 {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let radix = normalized.lowercased().hasPrefix("0x") ? 16 : 10
        let digits = radix == 16 ? String(normalized.dropFirst(2)) : normalized
        guard let value = UInt16(digits, radix: radix) else {
            throw DisplayControlError.invalidNumber(text)
        }
        return value
    }

    public static func uint8(_ text: String) throws -> UInt8 {
        let value = try uint16(text)
        guard value <= UInt16(UInt8.max) else {
            throw DisplayControlError.invalidNumber(text)
        }
        return UInt8(value)
    }
}
