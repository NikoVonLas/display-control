import DisplayCore
import Foundation

private let controller = HardwareDisplayController()

private func printUsage() {
    print(
        """
        acerctl — управление Acer XV282K KV через DDC/CI

        Команды:
          acerctl list
          acerctl get brightness
          acerctl set brightness <0...100>
          acerctl lighting status | resume | pause <минуты> | sync <on|off>
          acerctl lighting brightness <-90...100> [минуты] | lux <люксы>
          acerctl get input
          acerctl get vcp <код>
          acerctl profile mac
          acerctl profile pc [dp|hdmi1|hdmi2]
          acerctl set input <usb-c|dp|hdmi1|hdmi2|значение>
          acerctl set hub <usb-c|usb-b>
          acerctl set vcp <код> <значение>
          acerctl scan [путь.json]
          acerctl diff <до.json> <после.json>

        Коды и значения принимаются в десятичном виде или hex: 0x60.
        """
    )
}

private func target() throws -> ExternalDisplay {
    try controller.targetDisplay()
}

private func parseInput(_ text: String) throws -> UInt16 {
    switch text.lowercased() {
    case "usb-c", "usbc", "c":
        return VideoInput.usbC.rawValue
    case "dp", "displayport":
        return VideoInput.displayPort.rawValue
    case "hdmi1", "h1":
        return VideoInput.hdmi1.rawValue
    case "hdmi2", "h2":
        return VideoInput.hdmi2.rawValue
    default:
        return try NumberParser.uint16(text)
    }
}

private func formatted(_ snapshot: VCPFeatureSnapshot) -> String {
    "\(snapshot.codeHex) current=\(snapshot.current) (0x\(String(format: "%04X", snapshot.current))) max=\(snapshot.maximum) type=\(snapshot.type)"
}

private func parseHubRoute(_ text: String) throws -> HubRoute {
    switch text.lowercased() {
    case "usb-c", "usbc", "c":
        return .usbC
    case "usb-b", "usbb", "b":
        return .usbB
    default:
        throw DisplayControlError.invalidNumber(text)
    }
}

private func writeHubRoute(_ route: HubRoute, display: ExternalDisplay) throws {
    let configuration = HubCommandConfiguration.xv282KPatchedFirmware
    try controller.write(
        featureCode: configuration.featureCode,
        value: configuration.value(for: route),
        displayUUID: display.uuid
    )
}

private func writeProfile(input: UInt16, hubRoute: HubRoute, display: ExternalDisplay) throws {
    // Keep DDC on the currently active link until the hub command has been sent.
    try writeHubRoute(hubRoute, display: display)
    try controller.write(featureCode: 0x60, value: input, displayUUID: display.uuid)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        printUsage()
        return
    }

    let isBrightness = arguments.count == 3 && command == "set" && arguments[1].lowercased() == "brightness"
    if command == "lighting" || isBrightness {
        let request = isBrightness ? ["brightness", arguments[2]] : Array(arguments.dropFirst())
        if let reply = try AutomationPort.send(request) {
            guard reply.ok else { throw NSError(domain: "acerctl", code: 1, userInfo: [NSLocalizedDescriptionKey: reply.message]) }
            print(reply.message)
            return
        }
        if command == "lighting" {
            throw NSError(domain: "acerctl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Запустите Acer Display Control с поддержкой автоматизации"])
        }
    }
    switch command {
    case "help", "--help", "-h":
        printUsage()

    case "list":
        for display in try controller.displays() {
            let marker = display.isTargetAcer ? "*" : " "
            print("\(marker) \(display.productName) [\(display.manufacturer)] \(display.uuid)")
        }

    case "get":
        guard arguments.count >= 2 else {
            printUsage()
            return
        }
        let display = try target()
        let code: UInt8
        if arguments[1].lowercased() == "brightness" {
            let brightness = try controller.brightness(displayUUID: display.uuid)
            print("Подсветка: \(Int(brightness.percent.rounded()))% (\(brightness.current)/\(brightness.maximum))")
            return
        } else if arguments[1].lowercased() == "input" {
            code = 0x60
        } else if arguments[1].lowercased() == "vcp", arguments.count >= 3 {
            code = try NumberParser.uint8(arguments[2])
        } else {
            printUsage()
            return
        }
        print(formatted(try controller.read(featureCode: code, displayUUID: display.uuid)))

    case "profile":
        guard arguments.count >= 2 else {
            printUsage()
            return
        }
        let display = try target()
        switch arguments[1].lowercased() {
        case "mac":
            try writeProfile(input: VideoInput.usbC.rawValue, hubRoute: .usbC, display: display)
            print("Переключено: USB‑C video + USB‑C hub")
        case "pc":
            let input = try arguments.count >= 3
                ? parseInput(arguments[2])
                : VideoInput.displayPort.rawValue
            try writeProfile(input: input, hubRoute: .usbB, display: display)
            print("Переключено: video 0x\(String(format: "%02X", input)) + USB‑B hub")
        default:
            printUsage()
        }

    case "set":
        guard arguments.count >= 3 else {
            printUsage()
            return
        }
        let display = try target()
        if arguments[1].lowercased() == "brightness" {
            let percent = try NumberParser.uint16(arguments[2])
            let brightness = try controller.setBrightness(percent: Double(percent), displayUUID: display.uuid)
            print("Подсветка: \(Int(brightness.percent.rounded()))%")
        } else if arguments[1].lowercased() == "input" {
            let value = try parseInput(arguments[2])
            try controller.write(featureCode: 0x60, value: value, displayUUID: display.uuid)
            print("Записано: 0x60 = \(value)")
        } else if arguments[1].lowercased() == "hub" {
            let route = try parseHubRoute(arguments[2])
            try writeHubRoute(route, display: display)
            print("USB-хаб: \(route.title)")
        } else if arguments[1].lowercased() == "vcp", arguments.count >= 4 {
            let code = try NumberParser.uint8(arguments[2])
            let value = try NumberParser.uint16(arguments[3])
            try controller.write(featureCode: code, value: value, displayUUID: display.uuid)
            print("Записано: 0x\(String(format: "%02X", code)) = \(value)")
        } else {
            printUsage()
        }

    case "scan":
        let display = try target()
        let snapshots = controller.scan(displayUUID: display.uuid, progress: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshots)
        if arguments.count >= 2 {
            let url = URL(fileURLWithPath: arguments[1])
            try data.write(to: url, options: .atomic)
            print("Снимок сохранён: \(url.path) (\(snapshots.count) регистров)")
        } else {
            print(String(decoding: data, as: UTF8.self))
        }

    case "diff":
        guard arguments.count >= 3 else {
            printUsage()
            return
        }
        let decoder = JSONDecoder()
        let before = try decoder.decode(
            [VCPFeatureSnapshot].self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        )
        let after = try decoder.decode(
            [VCPFeatureSnapshot].self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        )
        let differences = HardwareDisplayController.differences(before: before, after: after)
        if differences.isEmpty {
            print("Изменившихся VCP-регистров не найдено")
        } else {
            for difference in differences {
                print(
                    "0x\(String(format: "%02X", difference.code)): " +
                        "\(difference.before.current) → \(difference.after.current) " +
                        "(max \(difference.after.maximum), type \(difference.after.type))"
                )
            }
        }

    default:
        printUsage()
    }
}

do {
    try run()
} catch {
    fputs("Ошибка: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
