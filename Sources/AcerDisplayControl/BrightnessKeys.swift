import AppKit
import ApplicationServices
import Combine

// Only the two display-brightness media keys are handled; all other events pass
// through. No keyboard text is inspected or recorded.
@MainActor
final class BrightnessKeys: ObservableObject {
    enum State: String { case accessRequired, unavailable, active }
    @Published private(set) var state: State = .accessRequired

    @Published private(set) var accessRequestPending = false
    private let isTrusted: () -> Bool
    private let prompt: () -> Void

    private func update(_ newState: State) {
        if state != newState { state = newState }
    }

    private func releaseTap() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopSourceInvalidate(source) }
        tap = nil
        source = nil
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let change: (Double) -> Bool

    init(isTrusted: @escaping () -> Bool = AXIsProcessTrusted,
         prompt: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         },
         change: @escaping (Double) -> Bool) {
        self.isTrusted = isTrusted
        self.prompt = prompt
        self.change = change
    }

    func startIfPermitted() {
        guard isTrusted() else {
            releaseTap()
            update(.accessRequired)
            return
        }
        if accessRequestPending { accessRequestPending = false }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            if CGEvent.tapIsEnabled(tap: tap) { update(.active); return }
        }
        releaseTap()
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    guard let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8,
                          let delta = BrightnessKeys.delta(data1: key.data1, modifiers: key.modifierFlags)
                    else { return Unmanaged.passUnretained(event) }
                    return owner.change(delta) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { update(.unavailable); return }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        update(CGEvent.tapIsEnabled(tap: port) ? .active : .unavailable)
    }

    nonisolated static func delta(data1: Int, modifiers: NSEvent.ModifierFlags) -> Double? {
        let key = (data1 >> 16) & 0xffff
        guard key == 2 || key == 3, ((data1 >> 8) & 0xff) == 0x0a else { return nil }
        let step = modifiers.contains([.shift, .option]) ? 1.0 : 6.25
        return key == 2 ? step : -step
    }

    func requestAccess() {
        guard !accessRequestPending, !isTrusted() else { return }
        accessRequestPending = true
        prompt()
    }

    // macOS provides no completion callback for a dismissed AX prompt. Allow
    // an explicit retry when the user next opens the app's settings window.
    func endSettingsSession() {
        if accessRequestPending { accessRequestPending = false }
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
