import Foundation
import CoreFoundation

public enum AutomationPort {
    public static var name: CFString { "dev.nikovonlas.acer-display-control.\(getuid())" as CFString }

    public struct Reply: Codable {
        public let ok: Bool
        public let message: String
        public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
    }

    public static func send(_ arguments: [String]) throws -> Reply? {
        guard let remote = CFMessagePortCreateRemote(nil, name) else { return nil }
        var reply: Unmanaged<CFData>?
        let data = try JSONEncoder().encode(arguments)
        let result = CFMessagePortSendRequest(remote, 1, data as CFData, 2, 15,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard result == kCFMessagePortSuccess, let reply else {
            throw NSError(domain: "acerctl", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "Нет подтверждения от приложения"])
        }
        return try JSONDecoder().decode(Reply.self, from: reply.takeRetainedValue() as Data)
    }
}
