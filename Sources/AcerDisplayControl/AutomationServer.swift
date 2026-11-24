import Foundation
import DisplayCore

@MainActor final class AutomationServer {
    private var port: CFMessagePort?
    private weak var store: DisplayStore?

    init(store: DisplayStore) {
        self.store = store
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, AutomationPort.name, { _, _, payload, context in
            guard let context, let payload, CFDataGetLength(payload) <= 2048,
                  let args = try? JSONDecoder().decode([String].self, from: payload as Data) else { return nil }
            let server = Unmanaged<AutomationServer>.fromOpaque(context).takeUnretainedValue()
            // The port runs on a background queue. Hardware work and GUI changes are serialized by DisplayStore.
            let completed = DispatchSemaphore(value: 0)
            var reply = AutomationPort.Reply(ok: false, message: "Приложение недоступно")
            Task { @MainActor in
                do {
                    if let store = server.store { reply = try await store.runAutomation(args) }
                } catch { reply = .init(ok: false, message: error.localizedDescription) }
                completed.signal()
            }
            completed.wait()
            guard let encoded = try? JSONEncoder().encode(reply) else { return nil }
            return Unmanaged.passRetained(encoded as CFData)
        }, &context, nil)
        if let port { CFMessagePortSetDispatchQueue(port, DispatchQueue(label: "acerctl.requests")) }
    }

    deinit { if let port { CFMessagePortInvalidate(port) } }
}
