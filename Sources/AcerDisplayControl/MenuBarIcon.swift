import AppKit

enum MenuBarIcon {
    static let mac = draw(macActive: true)
    static let pc = draw(macActive: false)

    private static func draw(macActive: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            func monitor(_ rect: NSRect, active: Bool) {
                let outline = NSBezierPath(roundedRect: rect, xRadius: 1.4, yRadius: 1.4)
                if active {
                    NSColor.black.withAlphaComponent(0.45).setFill()
                    outline.fill()
                }
                NSColor.black.setStroke()
                outline.lineWidth = 1.4
                outline.stroke()

                let stand = NSBezierPath()
                stand.lineWidth = 1.4
                stand.lineCapStyle = .round
                stand.move(to: NSPoint(x: rect.midX, y: rect.minY))
                stand.line(to: NSPoint(x: rect.midX, y: rect.minY - 2.2))
                stand.move(to: NSPoint(x: rect.midX - rect.width / 5, y: rect.minY - 2.2))
                stand.line(to: NSPoint(x: rect.midX + rect.width / 5, y: rect.minY - 2.2))
                stand.stroke()
            }
            // Match the overlapping silhouette of the original display.2 symbol.
            let rear = NSRect(x: 1, y: 4, width: 16, height: 11.5)
            let front = NSRect(x: 10.5, y: 3.5, width: 12.5, height: 8.5)
            NSGraphicsContext.saveGraphicsState()
            let visibleRear = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 18))
            visibleRear.append(NSBezierPath(roundedRect: front, xRadius: 1.4, yRadius: 1.4))
            visibleRear.windingRule = .evenOdd
            visibleRear.addClip()
            monitor(rear, active: macActive)
            NSGraphicsContext.restoreGraphicsState()
            monitor(front, active: !macActive)
            return true
        }
        image.isTemplate = true
        return image
    }
}
