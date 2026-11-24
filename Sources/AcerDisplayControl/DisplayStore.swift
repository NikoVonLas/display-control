import AppKit
import Combine
import CDDC
import DisplayCore
import Foundation

@MainActor
final class DisplayStore: ObservableObject {
    @Published private(set) var display: ExternalDisplay?
    @Published private(set) var currentInput: VideoInput?
    @Published private(set) var currentHubRoute: HubRoute?
    @Published private(set) var brightnessPercent: Double?
    @Published private(set) var brightnessAvailable = false
    @Published private(set) var isAdjustingBrightness = false
    @Published private(set) var isDisplayDisconnected = false
    @Published private(set) var disconnectDisplayForPC: Bool
    @Published private(set) var isBusy = false
    @Published var notice: String?
    let hubConfiguration = HubCommandConfiguration.xv282KPatchedFirmware

    private(set) lazy var brightnessKeys = BrightnessKeys { [weak self] delta in
        guard let self, !self.isBusy, self.currentInput == .usbC,
              !self.isDisplayDisconnected, self.brightnessAvailable,
              let brightness = self.brightnessPercent else { return false }
        self.setBrightness(min(100, max(-90, brightness + delta)))
        return true
    }

    private let controller: DisplayControlling
    private let defaults: UserDefaults
    private let lastHubRouteKey = "lastHubRoute"
    private let disconnectDisplayForPCKey = "disconnectDisplayForPC"
    private var isRefreshing = false
    private var revision = 0
    private var monitorTask: Task<Void, Never>?
    private var brightnessTask: Task<Void, Never>?
    private var brightnessRestoreUntil: Date?
    private var brightnessRestoreNotice: String?
    private var didRestoreBrightness = false
    private var lostBrightnessRead = false

    @Published var lighting: Lighting {
        didSet {
            if let data = try? JSONEncoder().encode(lighting) { defaults.set(data, forKey: "lighting.v1") }
            if oldValue.useSensor && !lighting.useSensor { stopSensor() }
        }
    }
    @Published private(set) var sensorStatus = ""
    private var sensorTask: Task<Void, Never>?
    private var sensorSubscription: Task<Void, Never>?
    private var nextSubscribe = Date.distantPast
    private var subscribed = false
    struct SourceStatus {
        let reading: HomeAssistantLight.Reading?
        let error: String?
        let name: String?
        let checkedAt: Date
    }
    @Published private(set) var sources: [LightSource]
    @Published private(set) var sourceStatus: [String: SourceStatus] = [:]
    @Published private(set) var winningEntity: String?
    private var pendingSources = Set<String>()
    private var sensorTokens = SensorTokenCache()
    private var nextSensorPoll = Date.distantPast
    private var server: AutomationServer?
    private let tint = ScreenTint()
    private var lastPeer: (uuid: String, percent: Double, primary: Double)?
    private var syncSettled = false
    private var retryPeerAfter = Date.distantPast
    @Published private(set) var benqMode: String?
    private var benqShade = 0.0
    private var manualSequence = 0
    private var completedManualSequence = 0

    var sensorHost: String { defaults.string(forKey: "haHost") ?? "" }

    func availableEntities(lamp: Bool) async throws -> [HomeAssistantLight.Entity] {
        let server = try HomeAssistantLight.serverURL(sensorHost)
        let token = try sensorTokens.token(for: HomeAssistantLight.account(for: server)) {
            try HomeAssistantLight.loadToken(for: server, interactive: false)
        }
        return try await HomeAssistantLight.entities(server: server, token: token, lamp: lamp)
    }

    func saveSource(_ draft: LightSource) throws {
        _ = try HomeAssistantLight.endpoint(server: sensorHost, entity: draft.entity, lamp: draft.isLamp)
        guard !sources.contains(where: { $0.id != draft.id && $0.entity == draft.entity }) else {
            throw LightSensorError("Этот источник уже добавлен.")
        }
        var source = draft
        source.conversion = try draft.conversion.validated(isLamp: draft.isLamp)
        var updated = sources
        if let index = updated.firstIndex(where: { $0.id == source.id }) { updated[index] = source }
        else { updated.append(source) }
        try saveSources(updated)
    }

    func removeSource(_ id: UUID) throws {
        try saveSources(sources.filter { $0.id != id })
    }

    private func saveSources(_ updated: [LightSource]) throws {
        defaults.set(try JSONEncoder().encode(updated), forKey: LightSource.storageKey)
        let oldSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var retained: [String: SourceStatus] = [:]
        for source in updated where oldSources[source.id] == source {
            retained[source.entity] = sourceStatus[source.entity]
        }
        stopSensor()
        sources = updated
        if !retained.isEmpty { applyReadings(retained) }
        if winningEntity == nil {
            lighting.lux = nil
            lighting.luxDate = nil
        }
        pollSensor()
    }

    func configureServer(host: String, token: String) throws {
        let url = try HomeAssistantLight.serverURL(host)
        let credential: String
        if token.isEmpty { credential = try HomeAssistantLight.loadToken(for: url, interactive: true) }
        else {
            try HomeAssistantLight.saveToken(token, for: url)
            credential = token
        }
        sensorTokens.remember(credential, for: HomeAssistantLight.account(for: url))
        stopSensor()
        lighting.lux = nil
        lighting.luxDate = nil
        defaults.set(url.absoluteString, forKey: "haHost")
        pollSensor()
    }

    private func stopSensor() {
        sensorTask?.cancel()
        sensorTask = nil
        sensorSubscription?.cancel()
        sensorSubscription = nil
        subscribed = false
        sourceStatus = [:]
        winningEntity = nil
        sensorStatus = ""
        pendingSources = []
        nextSensorPoll = .distantPast
        nextSubscribe = .distantPast
    }

    private func subscribeSensor(_ url: URL, token: String) {
        guard sensorSubscription == nil, Date() >= nextSubscribe else { return }
        let entities = sources.map(\.entity)
        sensorSubscription = Task { [weak self] in
            do {
                try await HomeAssistantLight.observe(url, entities: entities, token: token) { [weak self] entity in
                    guard let self, !Task.isCancelled, self.lighting.useSensor else { return }
                    self.subscribed = true
                    if let entity { self.pendingSources.insert(entity) }
                    else { self.nextSensorPoll = .distantPast }
                    self.pollSensor()
                }
            } catch { /* REST polling continues during reconnection. */ }
            guard let self, !Task.isCancelled else { return }
            self.subscribed = false
            self.sensorSubscription = nil
            self.nextSubscribe = Date().addingTimeInterval(5)
            self.nextSensorPoll = .distantPast
        }
    }

    private func pollSensor() {
        guard lighting.useSensor, !sensorHost.isEmpty, !sources.isEmpty, sensorTask == nil else { return }
        let fullPoll = Date() >= nextSensorPoll
        let batch = fullPoll ? sources : sources.filter { pendingSources.contains($0.entity) }
        pendingSources.removeAll()
        guard !batch.isEmpty else { return }
        if fullPoll { nextSensorPoll = Date().addingTimeInterval(subscribed ? 30 : 2) }
        let host = sensorHost
        sensorTask = Task {
            do {
                let url = try HomeAssistantLight.serverURL(host)
                let token = try sensorTokens.token(for: HomeAssistantLight.account(for: url)) {
                    try HomeAssistantLight.loadToken(for: url, interactive: false)
                }
                subscribeSensor(url, token: token)
                await withTaskGroup(of: (String, SourceStatus).self) { group in
                    for source in batch {
                        let oldName = sourceStatus[source.entity]?.name
                        group.addTask {
                            do {
                                let reading = try await HomeAssistantLight.read(source, server: host, token: token)
                                return (source.entity, SourceStatus(reading: reading, error: nil, name: reading.name ?? oldName, checkedAt: Date()))
                            } catch {
                                return (source.entity, SourceStatus(reading: nil, error: error.localizedDescription, name: oldName, checkedAt: Date()))
                            }
                        }
                    }
                    var updated = sourceStatus
                    for await (entity, result) in group { updated[entity] = result }
                    guard !Task.isCancelled else { return }
                    applyReadings(updated)
                }
            } catch {
                guard !Task.isCancelled else { return }
                sensorStatus = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            sensorTask = nil
            pollSensor()
        }
    }

    func applyReadings(_ updated: [String: SourceStatus]) {
        sourceStatus = updated
        let now = Date()
        var maximum: (entity: String, reading: HomeAssistantLight.Reading, checked: Date)?
        for source in sources {
            guard let state = updated[source.entity], let reading = state.reading,
                  now.timeIntervalSince(state.checkedAt) < 300 else { continue }
            if reading.lux > (maximum?.reading.lux ?? -.infinity) {
                maximum = (source.entity, reading, state.checkedAt)
            }
        }
        winningEntity = maximum?.entity
        guard let maximum else {
            sensorStatus = "Нет доступных показаний."
            return
        }
        sensorStatus = ""
        let changed = lighting.lux != maximum.reading.lux
        lighting.lux = maximum.reading.lux
        lighting.luxDate = maximum.checked
        if changed { refresh(reportErrors: false) }
    }

    private func targetLevel(_ input: VideoInput, _ uuid: String) -> Double? {
        if input == .usbC, let target = lighting.target(at: Date()) { return target }
        return savedBrightness(input, uuid)
    }

    func runAutomation(_ args: [String]) async throws -> AutomationPort.Reply {
        func fail(_ message: String) -> LightSensorError { LightSensorError(message) }
        func number(_ text: String, in range: ClosedRange<Double>) throws -> Double {
            guard let value = Double(text), value.isFinite, range.contains(value) else {
                throw fail("Значение вне диапазона \(range)")
            }
            return value
        }
        guard let action = args.first else { throw fail("Нужна команда") }
        switch (action, args.count) {
        case ("status", 1):
            var status: [String: Any] = ["schedule": lighting.schedule.rawValue, "sync": lighting.syncBenQ,
                                        "sensor": lighting.useSensor, "busy": isBusy || isAdjustingBrightness]
            status["benqMinimum"] = lighting.benqMinimum
            status["benqMode"] = benqMode
            status["benqHardwareBrightness"] = lastPeer?.percent
            status["benqSoftwareDimming"] = benqMode == "software" ? benqShade : nil
            status["brightnessKeys"] = brightnessKeys.state.rawValue
            status["brightness"] = brightnessPercent
            status["input"] = currentInput?.title
            status["target"] = lighting.target(at: Date())
            status["lux"] = lighting.lux
            if !sensorStatus.isEmpty { status["sensorError"] = sensorStatus }
            status["luxTimestamp"] = lighting.luxDate?.timeIntervalSince1970
            status["sensorSubscribed"] = subscribed
            status["sensorChangedAt"] = winningEntity.flatMap { sourceStatus[$0]?.reading?.changedAt?.timeIntervalSince1970 }
            status["winningEntity"] = winningEntity
            status["sources"] = sources.map { source in
                var entry: [String: Any] = ["entity": source.entity]
                entry["lux"] = sourceStatus[source.entity]?.reading?.lux
                entry["error"] = sourceStatus[source.entity]?.error
                return entry
            }
            status["measuredLux"] = sources.filter { !$0.isLamp }.compactMap { sourceStatus[$0.entity]?.reading?.lux }.max()
            status["estimatedLampLux"] = sources.filter(\.isLamp).compactMap { sourceStatus[$0.entity]?.reading?.lux }.max()
            status["pausedUntil"] = lighting.pauseUntil?.timeIntervalSince1970
            let data = try JSONSerialization.data(withJSONObject: status, options: .sortedKeys)
            return .init(ok: true, message: String(decoding: data, as: UTF8.self))
        case ("brightness", 2), ("brightness", 3):
            guard !isBusy, !isAdjustingBrightness, brightnessAvailable, let input = currentInput else {
                throw fail("Монитор занят или недоступен")
            }
            let level = try number(args[1], in: (input == .usbC ? -90.0 : 0)...100)
            let minutes = args.count == 3 ? try number(args[2], in: 1...1440) : 60
            setBrightness(level, holdMinutes: minutes)
            let sequence = manualSequence
            let task = brightnessTask
            await task?.value
            guard completedManualSequence == sequence else { throw fail(notice ?? "Изменение отменено") }
            return .init(ok: true, message: "Подсветка: \(level)%")
        case ("pause", 2):
            let minutes = try number(args[1], in: 1...1440)
            if currentInput == .usbC, let level = brightnessPercent, let display {
                rememberBrightness(level, input: .usbC, uuid: display.uuid)
            }
            lighting.pauseUntil = Date().addingTimeInterval(minutes*60)
        case ("resume", 1): lighting.pauseUntil = nil
        case ("lux", 2):
            lighting.lux = try number(args[1], in: 0...1_000_000)
            lighting.luxDate = Date()
            lighting.useSensor = true
        case ("sync", 2):
            guard ["on", "off"].contains(args[1]) else { throw fail("Ожидается on или off") }
            lighting.syncBenQ = args[1] == "on"
            retryPeerAfter = .distantPast
            syncSettled = false
        default: throw fail("Неизвестная команда lighting или неверные аргументы")
        }
        refresh(reportErrors: false)
        return .init(ok: true, message: "OK")
    }

    private func brightnessKey(_ input: VideoInput, _ uuid: String) -> String {
        "brightness.v1.\(uuid).\(input == .usbC ? "mac" : "pc")"
    }

    private func savedBrightness(_ input: VideoInput, _ uuid: String) -> Double? {
        guard let value = defaults.object(forKey: brightnessKey(input, uuid)) as? Double,
              value.isFinite, ((input == .usbC ? -90.0 : 0)...100).contains(value) else { return nil }
        return value
    }

    private func rememberBrightness(_ percent: Double, input: VideoInput, uuid: String) {
        guard percent.isFinite, ((input == .usbC ? -90.0 : 0)...100).contains(percent) else { return }
        defaults.set(percent, forKey: brightnessKey(input, uuid))
    }


    init(
        controller: DisplayControlling = HardwareDisplayController(),
        defaults: UserDefaults = .standard,
        automaticallyMonitor: Bool = true
    ) {
        self.controller = controller
        self.defaults = defaults
        sources = LightSource.load(from: defaults)
        self.lighting = defaults.data(forKey: "lighting.v1").flatMap { try? JSONDecoder().decode(Lighting.self, from: $0) } ?? Lighting()
        self.disconnectDisplayForPC = defaults.object(forKey: disconnectDisplayForPCKey) as? Bool ?? true

        if let storedHubRoute = defaults.string(forKey: lastHubRouteKey) {
            self.currentHubRoute = HubRoute(rawValue: storedHubRoute)
        }
        if automaticallyMonitor {
            startMonitoring()
            server = AutomationServer(store: self)
        }
    }

    deinit {
        sensorSubscription?.cancel()
        sensorTask?.cancel()
        monitorTask?.cancel()
        brightnessTask?.cancel()
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let _ = self else { return }
                self?.brightnessKeys.startIfPermitted()
                self?.pollSensor()
                self?.refresh(reportErrors: false)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func setBrightness(_ percent: Double, holdMinutes: Double = 60) {
        guard !isBusy, percent.isFinite, ((currentInput == .usbC ? -90.0 : 0)...100).contains(percent) else { return }
        manualSequence += 1
        let sequence = manualSequence
        brightnessTask?.cancel()
        brightnessRestoreUntil = nil
        brightnessPercent = percent
        isAdjustingBrightness = true
        revision += 1
        brightnessTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !isBusy else {
                isAdjustingBrightness = false
                return
            }
            isBusy = true
            notice = nil
            let controller = self.controller
            let knownDisplay = display
            let expectedInput = currentInput
            do {
                let brightness = try await Task.detached(priority: .userInitiated) {
                    let target = try knownDisplay ?? controller.targetDisplay()
                    let input = try controller.read(featureCode: 0x60, displayUUID: target.uuid)
                    guard let actualInput = VideoInput(rawValue: input.current) else {
                        throw DisplayControlError.hardware(code: -12, description: "Не удалось определить вход для сохранения яркости")
                    }
                    guard expectedInput == nil || actualInput == expectedInput else {
                        throw DisplayControlError.hardware(code: -12, description: "Монитор сменил вход. Обновите состояние и повторите изменение яркости.")
                    }
                    let brightness = try controller.setBrightness(percent: max(0, percent), displayUUID: target.uuid)
                    let confirmed = try controller.read(featureCode: 0x60, displayUUID: target.uuid)
                    guard confirmed.current == actualInput.rawValue else {
                        throw DisplayControlError.hardware(code: -12, description: "Вход изменился во время регулировки яркости")
                    }
                    return (target, actualInput, brightness)
                }.value
                rememberBrightness(percent, input: brightness.1, uuid: brightness.0.uuid)
                if brightness.1 == .usbC && (lighting.schedule != .off || lighting.useSensor) {
                    lighting.pauseUntil = Date().addingTimeInterval(holdMinutes*60)
                }
                completedManualSequence = sequence
                brightnessPercent = percent < 0 ? percent : brightness.2.percent
                brightnessAvailable = true
            } catch {
                brightnessAvailable = false
                show(error)
            }
            isAdjustingBrightness = false
            isBusy = false
        }
    }

    func refresh(reportErrors: Bool = true) {
        guard !isBusy, !isRefreshing, !isAdjustingBrightness else { return }
        isRefreshing = true
        let refreshRevision = revision
        let sync = lighting.syncBenQ
        if reportErrors {
            notice = nil
        }

        let controller = self.controller
        let knownDisplay = display
        Task {
            do {
                let configuration = self.hubConfiguration
                let state = try await Task.detached(priority: .userInitiated) { () -> (ExternalDisplay, VideoInput?, HubRoute?, Double?, ExternalDisplay?, Double?) in
                    // Keep using the known UUID when the monitor temporarily drops
                    // out of the online display list while changing inputs. The DDC
                    // bridge can continue through its cached transport.
                    let target = try resolveTarget(controller, knownDisplay: knownDisplay)
                    let inputValue = try? controller.read(featureCode: 0x60, displayUUID: target.uuid)
                    let input = inputValue.flatMap { VideoInput(rawValue: $0.current) }
                    let hubRoute: HubRoute?
                    if configuration.isEnabled,
                       let hubValue = try? controller.read(
                           featureCode: configuration.featureCode,
                           displayUUID: target.uuid
                       ) {
                        hubRoute = configuration.route(for: hubValue.current)
                    } else {
                        hubRoute = nil
                    }
                    let brightness = try? controller.brightness(displayUUID: target.uuid)
                    let confirmed = try? controller.read(featureCode: 0x60, displayUUID: target.uuid)
                    let stable = input != nil && confirmed?.current == input?.rawValue
                    let peer = sync && stable
                        ? try controller.displays().first(where: { $0.uuid != target.uuid && !controller.isBuiltIn(displayID: $0.id) && controller.isDisplayActive(displayID: $0.id) })
                        : nil
                    let peerLevel = peer.flatMap { try? controller.brightness(displayUUID: $0.uuid).percent }
                    return (target, stable ? input : nil, hubRoute, stable ? brightness?.percent : nil, peer, peerLevel)
                }.value

                guard refreshRevision == revision, !isBusy else {
                    isRefreshing = false
                    return
                }
                let reconnect = lostBrightnessRead || display?.id != state.0.id
                if state.1 == nil { lostBrightnessRead = true }
                else if state.3 != nil { lostBrightnessRead = false }
                let previousInput = currentInput
                display = state.0
                currentInput = state.1 ?? currentInput
                currentHubRoute = state.2
                brightnessAvailable = state.3 != nil && state.1 != nil
                // A failed DDC read is not 0%: retain the last meaningful value.
                if let measured = state.3 {
                    let desired = state.1.flatMap { targetLevel($0, state.0.uuid) } ?? measured
                    brightnessPercent = measured == 0 && desired < 0 ? desired : measured
                }
                if let input = state.1 {
                    if previousInput != input || (reconnect && state.3 != nil) {
                        didRestoreBrightness = false
                        brightnessRestoreUntil = Date().addingTimeInterval(10)
                        if savedBrightness(input, state.0.uuid) == nil {
                            let previous = previousInput.flatMap { savedBrightness($0, state.0.uuid) }
                            if let initial = previous ?? state.3 {
                                rememberBrightness(input == .usbC ? initial : max(0, initial), input: input, uuid: state.0.uuid)
                            }
                        }
                    }
                    let automatic = input == .usbC && lighting.target(at: Date()) != nil
                    let settling = !didRestoreBrightness && (brightnessRestoreUntil ?? .distantPast) > Date()
                    let desired = targetLevel(input, state.0.uuid)
                    if let desired, let measured = state.3, abs(measured - max(0, desired)) <= 0.5 {
                        clearBrightnessRestoreNotice()
                    }
                    let macActive = input == .usbC && controller.isDisplayActive(displayID: state.0.id)
                    let peer = lighting.syncBenQ ? state.4 : nil
                    let peerChanged = lastPeer?.uuid == peer?.uuid && lastPeer?.percent != state.5
                    if macActive, syncSettled, !automatic, previousInput == input, !reconnect,
                       peerChanged, lastPeer?.primary == state.3, let peerValue = state.5 {
                        setBrightness(peerValue)
                    } else if (automatic || settling), let desired,
                              state.3.map({ abs($0 - max(0, desired)) > 0.5 }) ?? true {
                        restoreBrightness(desired, input: input, target: state.0)
                    }
                    syncSettled = false
                    // The second monitor stays on the Mac desktop while Acer shows the PC.
                    // Its schedule therefore continues to use the Mac level.
                    let macLevel = macActive ? brightnessPercent : targetLevel(.usbC, state.0.uuid)
                    var extraShade: [UInt32: Double] = [:]
                    if let peer, let macLevel {
                        let hardwareLevel = max(0, macLevel)
                        if lastPeer?.uuid != peer.uuid && state.5 != nil { retryPeerAfter = .distantPast }
                        if let peerValue = state.5, let measured = state.3 {
                            lastPeer = (peer.uuid, peerValue, measured)
                            if abs(peerValue - hardwareLevel) <= 0.5 {
                                benqMode = "hardware"
                                syncSettled = macActive
                            } else if !isBusy && !isAdjustingBrightness && Date() >= retryPeerAfter {
                                isBusy = true
                                do {
                                    _ = try await Task.detached {
                                        try controller.setBrightness(percent: hardwareLevel, displayUUID: peer.uuid)
                                    }.value
                                    benqMode = "hardware"
                                } catch {
                                    benqMode = "software"
                                    retryPeerAfter = Date().addingTimeInterval(60)
                                }
                                isBusy = false
                            } else if Date() < retryPeerAfter {
                                benqMode = "software"
                            }
                        } else {
                            benqMode = "software"
                        }
                        if benqMode == "software" {
                            // Keep a visible hardware-minimum equivalent at logical 0%.
                            // Additional negative levels are applied by ScreenTint.
                            let measured = state.5 ?? lastPeer?.percent ?? 100
                            benqShade = lighting.benqSoftwareShade(at: hardwareLevel, hardwareBrightness: measured)
                            extraShade[peer.id] = benqShade
                            syncSettled = macActive && state.5 != nil
                        }
                    } else {
                        lastPeer = nil
                        benqMode = nil
                        retryPeerAfter = .distantPast
                    }
                    var ids: Set<UInt32> = macActive ? [state.0.id] : []
                    if let peer { ids.insert(peer.id) }
                    tint.apply(ids: ids, level: macLevel ?? 0, extraShade: extraShade)
                } else {
                    tint.apply(ids: [], level: 0)
                    syncSettled = false
                }
                isDisplayDisconnected = !controller.isDisplayActive(displayID: state.0.id)
                // Input switches can briefly remove the display, then reconnect it.
                // Reconcile the actual topology even while the menu is closed.
                if let input = currentInput {
                    let shouldDisconnect = disconnectDisplayForPC && input != .usbC
                    if isDisplayDisconnected != shouldDisconnect {
                        reconcileDisplay(enabled: !shouldDisconnect)
                    }
                }
            } catch {
                if refreshRevision == revision, !isBusy {
                    tint.apply(ids: [], level: 0)
                    lostBrightnessRead = true
                    brightnessAvailable = false
                }
                if reportErrors, refreshRevision == revision, !isBusy {
                    if knownDisplay == nil {
                        display = nil
                        currentInput = nil
                        currentHubRoute = nil
                    }
                    show(error)
                }
            }
            isRefreshing = false
        }
    }

    func setInput(_ input: VideoInput) {
        applyProfile(input: input, hubRoute: nil)
    }

    func setHubRoute(_ route: HubRoute) {
        guard hubConfiguration.isEnabled else {
            notice = "Переключение USB требует прошивку с VCP EA"
            return
        }

        let configuration = hubConfiguration
        perform { display in
            try self.controller.write(
                featureCode: configuration.featureCode,
                value: configuration.value(for: route),
                displayUUID: display.uuid
            )
        } completion: {
            self.currentHubRoute = route
            self.defaults.set(route.rawValue, forKey: self.lastHubRouteKey)
        }
    }

    func applyMacProfile() {
        applyProfile(input: .usbC, hubRoute: .usbC)
    }

    func applyPCProfile() {
        guard hubConfiguration.isEnabled else {
            notice = "Профиль PC требует прошивку с VCP EA"
            return
        }
        applyProfile(input: .displayPort, hubRoute: .usbB)
    }

    func setDisconnectDisplayForPC(_ enabled: Bool) {
        guard !isBusy else { return }
        revision += 1
        disconnectDisplayForPC = enabled
        defaults.set(enabled, forKey: disconnectDisplayForPCKey)

        if let currentInput {
            reconcileDisplay(enabled: !enabled || currentInput == .usbC)
        }
    }

    private func applyProfile(input: VideoInput, hubRoute: HubRoute?) {
        guard !isBusy else { return }
        let pendingBrightness = isAdjustingBrightness ? brightnessPercent : nil
        if input != .usbC, currentInput == .usbC { tint.apply(ids: [], level: 0) }
        brightnessTask?.cancel()
        isAdjustingBrightness = false
        revision += 1
        isBusy = true
        notice = nil

        let controller = self.controller
        let configuration = hubConfiguration
        let knownDisplay = display
        let shouldDisconnectDisplay = disconnectDisplayForPC && input != .usbC
        Task {
            do {
                let target = try await Task.detached(priority: .userInitiated) {
                    try resolveTarget(controller, knownDisplay: knownDisplay)
                }.value
                display = target
                let outgoing = await Task.detached(priority: .userInitiated) { () -> (VideoInput, Double)? in
                    guard let before = try? controller.read(featureCode: 0x60, displayUUID: target.uuid),
                          let source = VideoInput(rawValue: before.current),
                          let measured = try? controller.brightness(displayUUID: target.uuid),
                          let after = try? controller.read(featureCode: 0x60, displayUUID: target.uuid),
                          before.current == after.current else { return nil }
                    return (source, measured.percent)
                }.value
                if let outgoing, outgoing.0 == currentInput, target.uuid == knownDisplay?.uuid,
                   let pendingBrightness {
                    // The switch interrupted debounce. Attribute the slider choice
                    // only after confirming which monitor and input are leaving.
                    rememberBrightness(pendingBrightness, input: outgoing.0, uuid: target.uuid)
                    if outgoing.0 == .usbC && (lighting.schedule != .off || lighting.useSensor) {
                        lighting.pauseUntil = Date().addingTimeInterval(3600)
                    }
                } else if let outgoing,
                          !(outgoing.0 == .usbC && lighting.target(at: Date()) != nil),
                          brightnessRestoreUntil.map({ $0 <= Date() }) ?? true,
                          savedBrightness(outgoing.0, target.uuid) == nil ||
                          (outgoing.0 == currentInput && brightnessAvailable && outgoing.1 > 0) {
                    rememberBrightness(outgoing.1, input: outgoing.0, uuid: target.uuid)
                }
                if savedBrightness(input, target.uuid) == nil {
                    let source = outgoing?.0 ?? currentInput
                    if let initial = source.flatMap({ savedBrightness($0, target.uuid) }) ?? outgoing?.1 {
                        rememberBrightness(input == .usbC ? initial : max(0, initial), input: input, uuid: target.uuid)
                    }
                }
                try await Task.detached(priority: .userInitiated) {
                    if input == .usbC {
                        try controller.setDisplayEnabled(true, displayID: target.id)
                    }
                    if configuration.isEnabled, let hubRoute {
                        try controller.write(
                            featureCode: configuration.featureCode,
                            value: configuration.value(for: hubRoute),
                            displayUUID: target.uuid
                        )
                    }
                    try controller.write(featureCode: 0x60, value: input.rawValue, displayUUID: target.uuid)
                }.value
                // Keep the successful video switch even if the topology change
                // fails, so background monitoring can retry the disconnect.
                currentInput = input
                didRestoreBrightness = false
                brightnessRestoreUntil = Date().addingTimeInterval(10)
                if configuration.isEnabled, let hubRoute {
                    currentHubRoute = hubRoute
                    defaults.set(hubRoute.rawValue, forKey: lastHubRouteKey)
                }
                if let saved = targetLevel(input, target.uuid) {
                    do {
                        let restored = try await Task.detached(priority: .userInitiated) {
                            try restoreProfileBrightness(controller, percent: saved, input: input, target: target)
                        }.value
                        didRestoreBrightness = restored.didWrite
                        brightnessPercent = saved < 0 ? saved : restored.brightness.percent
                        brightnessAvailable = true
                    } catch {
                        brightnessAvailable = false
                        showBrightnessRestoreError(error, input: input)
                    }
                }
                display = try await Task.detached(priority: .userInitiated) {
                    let current = try resolveTarget(controller, knownDisplay: target)
                    try controller.setDisplayEnabled(!shouldDisconnectDisplay, displayID: current.id)
                    return current
                }.value
            } catch {
                show(error)
            }
            if let display {
                isDisplayDisconnected = !controller.isDisplayActive(displayID: display.id)
            }
            isBusy = false
        }
    }

    private func restoreBrightness(_ percent: Double, input: VideoInput, target: ExternalDisplay) {
        guard !isBusy else { return }
        let controller = self.controller
        revision += 1
        isBusy = true
        Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try restoreProfileBrightness(controller, percent: percent, input: input, target: target)
                }.value
                didRestoreBrightness = restored.didWrite
                brightnessPercent = percent < 0 ? percent : restored.brightness.percent
                brightnessAvailable = true
                clearBrightnessRestoreNotice()
            } catch {
                brightnessAvailable = false
                showBrightnessRestoreError(error, input: input)
            }
            isBusy = false
        }
    }

    private func reconcileDisplay(enabled: Bool) {
        guard !isBusy, let display else { return }
        revision += 1
        isBusy = true
        notice = nil

        let controller = self.controller
        Task {
            do {
                let target = try await Task.detached(priority: .userInitiated) {
                    let target = try resolveTarget(controller, knownDisplay: display)
                    try controller.setDisplayEnabled(enabled, displayID: target.id)
                    return target
                }.value
                self.display = target
                isDisplayDisconnected = !controller.isDisplayActive(displayID: target.id)
            } catch {
                show(error)
            }
            isBusy = false
        }
    }

    private func perform(
        operation: @escaping (ExternalDisplay) throws -> Void,
        completion: @escaping () -> Void
    ) {
        guard !isBusy else { return }
        revision += 1
        isBusy = true
        notice = nil

        let controller = self.controller
        let knownDisplay = display
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let target = try knownDisplay ?? controller.targetDisplay()
                    try operation(target)
                }.value
                completion()
            } catch {
                show(error)
            }
            isBusy = false
        }
    }

    private func showBrightnessRestoreError(_ error: Error, input: VideoInput) {
        let message = "Яркость на \(input.title): \(error.localizedDescription)"
        brightnessRestoreNotice = message
        notice = message
    }

    private func clearBrightnessRestoreNotice() {
        if let brightnessRestoreNotice, notice == brightnessRestoreNotice { notice = nil }
        brightnessRestoreNotice = nil
    }

    private func show(_ error: Error) {
        notice = error.localizedDescription
    }
}

// A hot-plug can assign a new CGDirectDisplayID to the same physical monitor.
private func resolveTarget(_ controller: DisplayControlling, knownDisplay: ExternalDisplay?) throws -> ExternalDisplay {
    let connected = try controller.displays()
    guard let knownDisplay else {
        if let acer = connected.first(where: { $0.isTargetAcer }) { return acer }
        throw DisplayControlError.noAcerDisplay
    }
    return connected.first(where: { $0.uuid == knownDisplay.uuid })
        ?? connected.first(where: {
            knownDisplay.serialNumber != 0 && $0.serialNumber == knownDisplay.serialNumber &&
            $0.vendorID == knownDisplay.vendorID && $0.modelID == knownDisplay.modelID
        }) ?? knownDisplay
}

// Input/picture settings settle asynchronously. Verify the destination before
// writing so a delayed input switch cannot apply PC brightness to the Mac.
private func restoreProfileBrightness(
    _ controller: DisplayControlling, percent: Double, input: VideoInput, target: ExternalDisplay
) throws -> (brightness: Brightness, didWrite: Bool) {
    let unsettled = DisplayControlError.hardware(code: -12, description: "Монитор ещё переключает вход. Яркость будет проверена повторно.")
    var previous: Brightness?
    var didWrite = false
    var remaining = 5
    var lastError: Error = unsettled
    while remaining > 0 {
        remaining -= 1
        Thread.sleep(forTimeInterval: 0.2)
        let measured: Brightness
        do {
            let selected = try controller.read(featureCode: 0x60, displayUUID: target.uuid)
            guard selected.current == input.rawValue else {
                previous = nil
                lastError = unsettled
                continue
            }
            measured = try controller.brightness(displayUUID: target.uuid)
            let confirmed = try controller.read(featureCode: 0x60, displayUUID: target.uuid)
            guard confirmed.current == input.rawValue else {
                previous = nil
                lastError = unsettled
                continue
            }
        } catch let DisplayControlError.hardware(code, message) where
            [ADC_ERROR_TRANSPORT_NOT_FOUND, ADC_ERROR_COMMUNICATION, ADC_ERROR_MALFORMED_REPLY].contains(Int(code)) {
            previous = nil
            lastError = DisplayControlError.hardware(code: code, description: message)
            continue
        }
        let raw = try measured.rawValue(percent: max(0, percent))
        if measured.current == raw { return (measured, didWrite) }
        if didWrite {
            lastError = DisplayControlError.hardware(code: -11, description: "Монитор не применил яркость. Проверьте HDR и режим изображения в меню монитора.")
        } else if previous == measured {
            // Once sent, only read back. A lost reply is not a failed write.
            try controller.write(featureCode: 0x10, value: raw, displayUUID: target.uuid)
            didWrite = true
            remaining = 4
        } else {
            previous = measured
            lastError = unsettled
        }
    }
    throw lastError
}
