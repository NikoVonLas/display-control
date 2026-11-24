import XCTest
@testable import DisplayCore

final class DisplayCoreTests: XCTestCase {
    func testXV282KInputMapping() {
        XCTAssertEqual(VideoInput.usbC.rawValue, 0x10)
        XCTAssertEqual(VideoInput.displayPort.rawValue, 0x0F)
        XCTAssertEqual(VideoInput.hdmi1.rawValue, 0x11)
        XCTAssertEqual(VideoInput.hdmi2.rawValue, 0x12)
    }

    func testFlexibleNumberParser() throws {
        XCTAssertEqual(try NumberParser.uint16("0xE7"), 231)
        XCTAssertEqual(try NumberParser.uint16("255"), 255)
        XCTAssertThrowsError(try NumberParser.uint8("0x100"))
    }

    func testSnapshotDiff() {
        let before = [
            VCPFeatureSnapshot(code: 0x60, type: 0, maximum: 255, current: 0x10),
            VCPFeatureSnapshot(code: 0xE7, type: 0, maximum: 3, current: 1)
        ]
        let after = [
            VCPFeatureSnapshot(code: 0x60, type: 0, maximum: 255, current: 0x10),
            VCPFeatureSnapshot(code: 0xE7, type: 0, maximum: 3, current: 2)
        ]

        let differences = HardwareDisplayController.differences(before: before, after: after)
        XCTAssertEqual(differences.map(\.code), [0xE7])
    }

    func testHubConfigurationMapping() {
        let configuration = HubCommandConfiguration(
            isEnabled: true,
            featureCode: 0xE7,
            usbCValue: 1,
            usbBValue: 2
        )
        XCTAssertEqual(configuration.value(for: .usbC), 1)
        XCTAssertEqual(configuration.route(for: 2), .usbB)
        XCTAssertNil(configuration.route(for: 3))
    }

    func testXV282KPatchedHubCommand() {
        let configuration = HubCommandConfiguration.xv282KPatchedFirmware
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.featureCode, 0xEA)
        XCTAssertEqual(configuration.value(for: .usbC), 1)
        XCTAssertEqual(configuration.value(for: .usbB), 0)
        XCTAssertEqual(configuration.route(for: 0), .usbB)
        XCTAssertEqual(configuration.route(for: 1), .usbC)
    }

    func testConfigurationStoreMigratesV1Mapping() throws {
        let suiteName = "DisplayCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let experimental = HubCommandConfiguration(
            isEnabled: true,
            featureCode: 0xEA,
            usbCValue: 0,
            usbBValue: 1
        )
        defaults.set(try JSONEncoder().encode(experimental), forKey: "hubCommandConfiguration")
        defaults.set(1, forKey: "hubCommandConfigurationVersion")

        let migrated = ConfigurationStore(defaults: defaults).loadHubConfiguration()
        XCTAssertEqual(migrated, .xv282KPatchedFirmware)
    }
}
