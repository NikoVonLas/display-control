import XCTest
import AppKit
import DisplayCore
@testable import AcerDisplayControl

private final class MockDisplayController: DisplayControlling {
    private let lock = NSLock()
    private var _displayID: UInt32 = 42
    private var _active = true
    private var _input = VideoInput.usbC.rawValue
    private var _brightness: UInt16 = 140
    private var _calls: [String] = []
    var nextDisplayIDOnInputWrite: UInt32?
    var transitionReadings: [UInt16] = []
    private var remainingReadings: [UInt16] = []
    var withBenQ = false
    var benqLocked = false
    private var benqLevel: UInt16 = 70
    var malformedReadsAfterInputWrite = 0
    var malformedReadsAfterBrightnessWrite = 0
    private var malformedReadsRemaining = 0
    var resetBrightnessOnSwitch = false
    var failBrightnessRead = false
    var failDisconnect = false
    var failInputRead = false
    var ignoreBrightnessWrites = false
    var displayID: UInt32 {
        get { lock.withLock { _displayID } }
        set { lock.withLock { _displayID = newValue } }
    }
    var active: Bool {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }
    var input: UInt16 {
        get { lock.withLock { _input } }
        set { lock.withLock { _input = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }
    func displays() throws -> [ExternalDisplay] {
        var displays = [try targetDisplay()]
        if withBenQ {
            displays.append(.init(id: 500, uuid: "benq-test", productName: "External LCD", manufacturer: "TST",
                                  vendorID: 2, modelID: 2, serialNumber: 2))
        }
        return displays
    }
    func targetDisplay() throws -> ExternalDisplay {
        ExternalDisplay(id: displayID, uuid: "acer-test", productName: "XV282K", manufacturer: "ACR", vendorID: 1, modelID: 1, serialNumber: 1)
    }
    func read(featureCode: UInt8, displayUUID: String) throws -> VCPFeatureSnapshot {
        try lock.withLock {
            if displayUUID == "benq-test" {
                return .init(code: featureCode, type: 0, maximum: 100, current: benqLevel)
            }
            if malformedReadsRemaining > 0 {
                malformedReadsRemaining -= 1
                throw DisplayControlError.hardware(code: -5, description: "Malformed DDC reply")
            }
            if featureCode == 0x10 && failBrightnessRead { throw DisplayControlError.noAcerDisplay }
            if featureCode == 0x60 && failInputRead { throw DisplayControlError.noAcerDisplay }
            if featureCode == 0x10 && !remainingReadings.isEmpty {
                _brightness = remainingReadings.removeFirst()
            }
            let current: UInt16 = featureCode == 0x60 ? _input : featureCode == 0x10 ? _brightness : 1
            return VCPFeatureSnapshot(code: featureCode, type: 0, maximum: featureCode == 0x10 ? 200 : 255, current: current)
        }
    }
    func write(featureCode: UInt8, value: UInt16, displayUUID: String) throws {
        lock.withLock {
            if displayUUID == "benq-test" {
                if !benqLocked { benqLevel = value }
                _calls.append("benq:\(value)")
                return
            }
            _calls.append("write:\(featureCode):\(value)")
            if featureCode == 0x60 {
                if resetBrightnessOnSwitch { _brightness = 0 }
                malformedReadsRemaining = malformedReadsAfterInputWrite
                remainingReadings = transitionReadings
                _input = value
                if let nextDisplayIDOnInputWrite { _displayID = nextDisplayIDOnInputWrite }
            }
            if featureCode == 0x10 && !ignoreBrightnessWrites {
                _brightness = value
                malformedReadsRemaining = malformedReadsAfterBrightnessWrite
            }
        }
    }
    func setDisplayEnabled(_ enabled: Bool, displayID: UInt32) throws {
        try lock.withLock {
            _calls.append("enabled:\(displayID):\(enabled)")
            if !enabled && failDisconnect { throw DisplayControlError.hardware(code: -7, description: "disconnect failed") }
            if displayID == _displayID { _active = enabled }
        }
    }
    func isBuiltIn(displayID: UInt32) -> Bool { false }
    func isDisplayActive(displayID: UInt32) -> Bool { lock.withLock { (displayID == _displayID && _active) || (displayID == 500 && withBenQ) } }
    func scan(displayUUID: String, progress: ((Int) -> Void)?) -> [VCPFeatureSnapshot] { [] }
}

final class DisplayStoreTests: XCTestCase {
    @MainActor private func makeStore(_ controller: MockDisplayController, defaults sharedDefaults: UserDefaults? = nil) -> DisplayStore {
        let defaults = sharedDefaults ?? UserDefaults(suiteName: "DisplayStoreTests.\(UUID().uuidString)")!
        return DisplayStore(controller: controller, defaults: defaults, automaticallyMonitor: false)
    }

    @MainActor func testMultipleSourcesMigrateAndIgnoreFailedOrStaleReadings() throws {
        let suite = "LightSources.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://home.example", forKey: "haHost")
        defaults.set("sensor.first", forKey: "haSensor")
        defaults.set(try JSONEncoder().encode(LampCalibration(entity: "light.first", warmLux: 40, coolLux: 80)), forKey: "haLampCalibration")
        let store = makeStore(MockDisplayController(), defaults: defaults)
        XCTAssertEqual(store.sources.map(\.entity), ["sensor.first", "light.first"])
        XCTAssertEqual(store.sources[1].conversion, .color(warm: 40, cool: 80))
        try store.saveSource(.init(entity: "light.second", conversion: .points([.init(input: 100, lux: 80)])))
        try store.saveSource(.init(entity: "sensor.second", conversion: .standard))
        XCTAssertThrowsError(try store.saveSource(.init(entity: "sensor.first", conversion: .standard)))
        var edited = store.sources[2]
        edited.entity = "light.office"
        try store.saveSource(edited)
        XCTAssertEqual(store.sources.count, 4)
        XCTAssertEqual(LightSource.load(from: defaults), store.sources)
        func status(_ lux: Double?, age: Double = 0) -> DisplayStore.SourceStatus {
            .init(reading: lux.map { .init(lux: $0, changedAt: nil) }, error: nil, name: nil, checkedAt: Date().addingTimeInterval(-age))
        }
        store.applyReadings(["light.office": status(nil), "sensor.first": status(99, age: 301), "sensor.second": status(51), "light.first": status(20)])
        XCTAssertEqual(store.winningEntity, "sensor.second")
        XCTAssertEqual(store.lighting.lux, 51)
        for source in store.sources { try store.removeSource(source.id) }
        XCTAssertTrue(LightSource.load(from: defaults).isEmpty)
        XCTAssertNil(store.lighting.lux)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for state")
    }

    func testBrightnessScalingAndValidation() throws {
        let brightness = try Brightness(snapshot: .init(code: 0x10, type: 0, maximum: 200, current: 140))
        XCTAssertEqual(brightness.percent, 70)
        XCTAssertEqual(try brightness.rawValue(percent: 25), 50)
        XCTAssertEqual(try brightness.rawValue(percent: 0), 0)
        XCTAssertEqual(try brightness.rawValue(percent: 100), 200)
        for invalid in [-1.0, 101, .nan, .infinity] {
            XCTAssertThrowsError(try brightness.rawValue(percent: invalid))
        }
        XCTAssertThrowsError(try Brightness(snapshot: .init(code: 0x10, type: 0, maximum: 0, current: 0)))
    }

    func testBrightnessWriteReadbackAndLockedMode() throws {
        let controller = MockDisplayController()
        XCTAssertEqual(try controller.setBrightness(percent: 25, displayUUID: "acer-test").current, 50)
        controller.ignoreBrightnessWrites = true
        XCTAssertThrowsError(try controller.setBrightness(percent: 80, displayUUID: "acer-test"))
    }

    @MainActor func testPollingLeavesExternallyInactiveMacDisplayAlone() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        for active in [true, false, false, true, false] {
            controller.active = active
            store.refresh(reportErrors: false)
            try await waitUntil { !store.isRefreshing && !store.isBusy }
            XCTAssertEqual(store.isDisplayDisconnected, !active)
        }
        XCTAssertTrue(controller.calls.isEmpty)
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(controller.active)
    }

    @MainActor func testExternalSwitchToMacRestoresOnlyOurDisconnect() async throws {
        for initiallyActive in [true, false] {
            let controller = MockDisplayController()
            controller.active = initiallyActive
            let store = makeStore(controller)
            store.applyPCProfile()
            try await waitUntil { !store.isBusy }
            controller.input = VideoInput.usbC.rawValue
            store.refresh(reportErrors: false)
            try await waitUntil { !store.isRefreshing && !store.isBusy }
            XCTAssertEqual(controller.active, initiallyActive)
            controller.active = false // Screen sharing takes over the desktop.
            store.refresh(reportErrors: false)
            try await waitUntil { !store.isRefreshing && !store.isBusy }
            XCTAssertFalse(controller.active)
        }
    }

    @MainActor func testFailedBackgroundDisconnectWaitsForNewStateOrManualRetry() async throws {
        let controller = MockDisplayController()
        controller.input = VideoInput.displayPort.rawValue
        controller.failDisconnect = true
        let store = makeStore(controller)
        for _ in 0..<3 {
            store.refresh(reportErrors: false)
            try await waitUntil { !store.isRefreshing && !store.isBusy }
        }
        XCTAssertEqual(controller.calls.filter { $0 == "enabled:42:false" }.count, 1)
        controller.failDisconnect = false
        store.refresh()
        try await waitUntil { !store.isRefreshing && !store.isBusy }
        XCTAssertTrue(store.isDisplayDisconnected)
    }

    @MainActor func testPCProfileDisconnectAndMacRestoreOrder() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.currentInput, .displayPort)
        XCTAssertTrue(store.isDisplayDisconnected)
        XCTAssertEqual(controller.calls.filter { !$0.hasPrefix("write:16:") }, ["write:234:0", "write:96:15", "enabled:42:false"])
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertFalse(store.isDisplayDisconnected)
        XCTAssertEqual(Array(controller.calls.filter { !$0.hasPrefix("write:16:") }.suffix(4)), ["enabled:42:true", "write:234:1", "write:96:16", "enabled:42:true"])
    }

    @MainActor func testReconnectWithNewDisplayIDIsDisconnectedEvenWithoutDDCReply() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        controller.displayID = 99
        controller.active = true
        controller.failInputRead = true
        store.refresh()
        try await waitUntil { controller.calls.contains("enabled:99:false") && !store.isBusy }
        XCTAssertEqual(store.display?.id, 99)
        XCTAssertTrue(store.isDisplayDisconnected)
    }

    @MainActor func testDisplayIDChangesDuringInputSwitch() async throws {
        let controller = MockDisplayController()
        controller.nextDisplayIDOnInputWrite = 77
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.display?.id, 77)
        XCTAssertTrue(store.isDisplayDisconnected)
        XCTAssertTrue(controller.calls.contains("enabled:77:false"))
        XCTAssertFalse(controller.calls.contains("enabled:42:false"))
    }

    @MainActor func testFailedDisconnectKeepsInputAndCanBeRetried() async throws {
        let controller = MockDisplayController()
        controller.failDisconnect = true
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.currentInput, .displayPort)
        XCTAssertFalse(store.isDisplayDisconnected)
        XCTAssertEqual(store.notice, "disconnect failed")
        controller.failDisconnect = false
        store.refresh()
        try await waitUntil { store.isDisplayDisconnected && !store.isBusy }
    }

    @MainActor func testDisabledPreferenceDoesNotDisconnectPC() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.setDisconnectDisplayForPC(false)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(controller.active)
        XCTAssertFalse(controller.calls.contains("enabled:42:false"))
    }

    @MainActor func testBrightnessDebouncesSliderChanges() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.setBrightness(30)
        store.setBrightness(40)
        store.setBrightness(50)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 50)
        XCTAssertEqual(controller.calls.filter { $0.hasPrefix("write:16:") }, ["write:16:100"])
    }
    @MainActor func testSeparateBrightnessSurvivesResetAndRelaunch() async throws {
        let controller = MockDisplayController()
        controller.resetBrightnessOnSwitch = true
        let suite = "BrightnessMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(controller, defaults: defaults)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        store.setBrightness(80)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 80) // first PC visit inherits Mac
        store.setBrightness(35)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 80)
        let relaunched = makeStore(controller, defaults: defaults)
        relaunched.applyPCProfile()
        try await waitUntil { !relaunched.isBusy }
        XCTAssertEqual(relaunched.brightnessPercent, 35)
        XCTAssertEqual(try controller.brightness(displayUUID: "acer-test").percent, 35)
    }

    @MainActor func testSwitchDuringSliderDebouncePreservesOutgoingChoice() async throws {
        let controller = MockDisplayController()
        controller.resetBrightnessOnSwitch = true
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        store.setBrightness(45)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        store.setBrightness(20)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 45)
    }

    @MainActor func testUnavailableBrightnessDoesNotBecomeZero() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        XCTAssertEqual(store.brightnessPercent, 70)
        controller.failBrightnessRead = true
        store.refresh()
        try await waitUntil { !store.brightnessAvailable }
        XCTAssertEqual(store.brightnessPercent, 70)
        XCTAssertFalse(controller.calls.contains("write:16:0"))
    }

    @MainActor func testIntentionalZeroIsRememberedAndRestored() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        store.setBrightness(0)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        store.setBrightness(40)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 0)
    }

    @MainActor func testAutomaticInputFallbackDoesNotOverwriteOtherComputer() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        store.setBrightness(90)
        try await waitUntil { !store.isBusy && !store.isAdjustingBrightness }
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        controller.input = VideoInput.usbC.rawValue // no PC signal: monitor auto-returns
        store.setBrightness(60)
        try await waitUntil { !store.isBusy && !store.isAdjustingBrightness }
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(controller.calls.contains("write:16:120"))
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 90, "Rejected slider change must preserve the PC preset")
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 90)
    }

    @MainActor func testReconnectOnSameInputRestoresBrightness() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        store.setBrightness(55)
        try await waitUntil { !store.isAdjustingBrightness && !store.isBusy }
        controller.failInputRead = true
        store.refresh()
        try await waitUntil { !store.brightnessAvailable }
        try controller.write(featureCode: 0x10, value: 200, displayUUID: "acer-test")
        controller.failInputRead = false
        store.refresh()
        try await waitUntil { store.brightnessAvailable && !store.isBusy }
        XCTAssertEqual(try XCTUnwrap(store.brightnessPercent), 55, accuracy: 0.001)
    }

    @MainActor func testTransientZeroDuringRoundTripNeedsNoBrightnessWrites() async throws {
        let controller = MockDisplayController()
        controller.transitionReadings = [0, 140]
        let store = makeStore(controller)
        for input in [VideoInput.displayPort, .usbC, .displayPort, .usbC] {
            store.setInput(input)
            try await waitUntil { !store.isBusy }
            XCTAssertEqual(store.brightnessPercent, 70)
        }
        XCTAssertFalse(controller.calls.contains { $0.hasPrefix("write:16:") })
    }

    @MainActor func testProfileRestoresOnceWithMalformedReadsBeforeAndAfterWrite() async throws {
        let controller = MockDisplayController()
        controller.malformedReadsAfterInputWrite = 2
        controller.malformedReadsAfterBrightnessWrite = 2
        controller.resetBrightnessOnSwitch = true
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.currentInput, .displayPort)
        XCTAssertTrue(store.brightnessAvailable)
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.brightnessPercent, 70)
        XCTAssertEqual(controller.calls.filter { $0.hasPrefix("write:16:") }, ["write:16:140"])
    }

    @MainActor func testPersistentReadFailureIsReportedUntilBrightnessConfirmed() async throws {
        let controller = MockDisplayController()
        controller.malformedReadsAfterInputWrite = 5
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertFalse(store.brightnessAvailable)
        XCTAssertTrue(store.notice?.contains("Malformed DDC reply") == true)
        store.refresh(reportErrors: false)
        try await waitUntil { store.brightnessAvailable }
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.brightnessPercent, 70)
        XCTAssertFalse(controller.calls.contains { $0.hasPrefix("write:16:") })
    }

    @MainActor func testConfirmedRestoreDoesNotFightLaterBrightnessChange() async throws {
        let controller = MockDisplayController()
        controller.resetBrightnessOnSwitch = true
        let store = makeStore(controller)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(controller.calls.filter { $0.hasPrefix("write:16:") }, ["write:16:140"])
        try controller.write(featureCode: 0x10, value: 80, displayUUID: "acer-test")
        store.refresh()
        try await waitUntil { store.brightnessPercent == 40 && !store.isBusy }
        XCTAssertEqual(controller.calls.filter { $0.hasPrefix("write:16:") }, ["write:16:140", "write:16:80"])
    }

    @MainActor func testAutomationManualOverrideAndResumePreserveProfiles() async throws {
        let controller = MockDisplayController()
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        _ = try await store.runAutomation(["brightness", "-25", "10"])
        XCTAssertEqual(store.brightnessPercent, -25)
        XCTAssertEqual(try controller.brightness(displayUUID: "acer-test").percent, 0)
        _ = try await store.runAutomation(["lux", "0"])
        try await waitUntil { store.brightnessPercent == 35 && !store.isBusy }
        _ = try await store.runAutomation(["brightness", "55", "10"])
        XCTAssertTrue(store.lighting.isPaused(at: Date()))
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        _ = try await store.runAutomation(["brightness", "67"])
        _ = try await store.runAutomation(["resume"])
        store.applyMacProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent, 35)
        store.applyPCProfile()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.brightnessPercent ?? -1, 67, accuracy: 0.001)
    }

    @MainActor func testBenQChangesPropagateInBothDirections() async throws {
        let controller = MockDisplayController()
        controller.withBenQ = true
        let store = makeStore(controller)
        _ = try await store.runAutomation(["sync", "on"])
        try await waitUntil { store.brightnessAvailable }
        try controller.write(featureCode: 0x10, value: 40, displayUUID: "benq-test")
        store.refresh()
        try await waitUntil { controller.calls.contains("write:16:80") && !store.isAdjustingBrightness }
        XCTAssertEqual(store.brightnessPercent, 40)
        _ = try await store.runAutomation(["brightness", "65"])
        store.refresh()
        try await waitUntil { controller.calls.contains("benq:65") && !store.isBusy }
        XCTAssertEqual(try controller.brightness(displayUUID: "benq-test").percent, 65)
    }

    @MainActor func testLockedBenQFallsBackToSoftwareWithoutRepeatedWrites() async throws {
        let controller = MockDisplayController()
        controller.withBenQ = true
        controller.benqLocked = true
        let store = makeStore(controller)
        store.refresh()
        try await waitUntil { store.brightnessAvailable }
        _ = try await store.runAutomation(["brightness", "30"])
        _ = try await store.runAutomation(["sync", "on"])
        try await waitUntil { store.benqMode == "software" && !store.isBusy }
        let reply = try await store.runAutomation(["status"])
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.message.utf8)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(status["benqSoftwareDimming"] as? Double), 2.0 / 7, accuracy: 0.0001)
        XCTAssertEqual(controller.calls.filter { $0 == "benq:30" }.count, 1)
    }

    @MainActor func testAccessPromptIsSentOnceWhileUserGrantsPermission() {
        var prompts = 0
        var trusted = false
        let keys = BrightnessKeys(isTrusted: { trusted }, prompt: { prompts += 1 }, change: { _ in false })
        keys.requestAccess()
        keys.startIfPermitted() // a background check while System Settings is open
        keys.requestAccess()
        XCTAssertTrue(keys.accessRequestPending)
        XCTAssertEqual(prompts, 1)
        keys.endSettingsSession()
        keys.requestAccess() // a deliberate retry after closing the original request
        XCTAssertEqual(prompts, 2)
        keys.endSettingsSession()
        trusted = true
        keys.requestAccess()
        XCTAssertEqual(prompts, 2)
    }

    func testBrightnessMediaKeyFiltering() {
        XCTAssertEqual(BrightnessKeys.delta(data1: (2 << 16) | 0x0a00, modifiers: []), 6.25)
        XCTAssertEqual(BrightnessKeys.delta(data1: (3 << 16) | 0x0a00, modifiers: [.shift, .option]), -1)
        XCTAssertNil(BrightnessKeys.delta(data1: (2 << 16) | 0x0b00, modifiers: [])) // release
        XCTAssertNil(BrightnessKeys.delta(data1: (0 << 16) | 0x0a00, modifiers: [])) // volume
        XCTAssertNil(BrightnessKeys.delta(data1: (21 << 16) | 0x0a00, modifiers: [])) // keyboard backlight
    }

}
