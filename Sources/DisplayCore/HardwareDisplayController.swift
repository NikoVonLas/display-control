import Foundation
import CoreGraphics
@preconcurrency import CDDC

public protocol DisplayControlling: AnyObject {
    func displays() throws -> [ExternalDisplay]
    func targetDisplay() throws -> ExternalDisplay
    func read(featureCode: UInt8, displayUUID: String) throws -> VCPFeatureSnapshot
    func write(featureCode: UInt8, value: UInt16, displayUUID: String) throws
    func setDisplayEnabled(_ enabled: Bool, displayID: UInt32) throws
    func isBuiltIn(displayID: UInt32) -> Bool
    func isDisplayActive(displayID: UInt32) -> Bool
    func scan(displayUUID: String, progress: ((Int) -> Void)?) -> [VCPFeatureSnapshot]
}

public final class HardwareDisplayController: DisplayControlling {
    public init() {}

    public func displays() throws -> [ExternalDisplay] {
        var rawDisplays = Array(repeating: ADCDisplayInfo(), count: 16)
        let count = rawDisplays.withUnsafeMutableBufferPointer { buffer in
            ADCListDisplays(buffer.baseAddress, Int32(buffer.count))
        }

        guard count >= 0 else {
            throw hardwareError(count)
        }

        return rawDisplays.prefix(Int(count)).map(Self.convert)
    }

    public func targetDisplay() throws -> ExternalDisplay {
        let connected = try displays()
        guard let display = connected.first(where: { $0.isTargetAcer }) else {
            throw DisplayControlError.noAcerDisplay
        }
        return display
    }

    public func read(featureCode: UInt8, displayUUID: String) throws -> VCPFeatureSnapshot {
        var reply = ADCVCPReply()
        let result = displayUUID.withCString { uuid in
            ADCReadVCP(uuid, featureCode, &reply)
        }

        guard result == ADC_SUCCESS else {
            throw hardwareError(result)
        }

        return VCPFeatureSnapshot(
            code: reply.featureCode,
            type: reply.typeCode,
            maximum: reply.maximumValue,
            current: reply.currentValue
        )
    }

    public func write(featureCode: UInt8, value: UInt16, displayUUID: String) throws {
        let result = displayUUID.withCString { uuid in
            ADCWriteVCP(uuid, featureCode, value)
        }

        guard result == ADC_SUCCESS else {
            throw hardwareError(result)
        }
    }

    public func setDisplayEnabled(_ enabled: Bool, displayID: UInt32) throws {
        let result = ADCSetDisplayEnabled(displayID, enabled)
        guard result == ADC_SUCCESS else {
            throw hardwareError(result)
        }
    }

    public func isBuiltIn(displayID: UInt32) -> Bool { CGDisplayIsBuiltin(displayID) != 0 }

    public func isDisplayActive(displayID: UInt32) -> Bool {
        ADCDisplayIsActive(displayID)
    }

    public func scan(displayUUID: String, progress: ((Int) -> Void)? = nil) -> [VCPFeatureSnapshot] {
        var values: [VCPFeatureSnapshot] = []

        for integerCode in 1...255 {
            let code = UInt8(integerCode)
            if let value = try? read(featureCode: code, displayUUID: displayUUID) {
                values.append(value)
            }
            progress?(integerCode)
        }

        return values
    }

    public static func differences(
        before: [VCPFeatureSnapshot],
        after: [VCPFeatureSnapshot]
    ) -> [VCPDifference] {
        let beforeByCode = Dictionary(uniqueKeysWithValues: before.map { ($0.code, $0) })
        let afterByCode = Dictionary(uniqueKeysWithValues: after.map { ($0.code, $0) })

        return beforeByCode.keys.sorted().compactMap { code in
            guard let earlier = beforeByCode[code], let later = afterByCode[code], earlier != later else {
                return nil
            }
            return VCPDifference(code: code, before: earlier, after: later)
        }
    }

    private static func convert(_ rawValue: ADCDisplayInfo) -> ExternalDisplay {
        var value = rawValue
        return ExternalDisplay(
            id: value.displayID,
            uuid: decodeCString(&value.uuid),
            productName: decodeCString(&value.productName),
            manufacturer: decodeCString(&value.manufacturer),
            vendorID: value.vendorID,
            modelID: value.modelID,
            serialNumber: value.serialNumber
        )
    }

    private static func decodeCString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return ""
            }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }

    private func hardwareError(_ code: Int32) -> DisplayControlError {
        let description = String(cString: ADCErrorDescription(code))
        return .hardware(code: code, description: description)
    }
}
