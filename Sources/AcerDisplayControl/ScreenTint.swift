import AppKit

/// Click-through windows scoped to the selected physical screens. Closing an
/// overlay immediately restores the underlying picture, including on app exit.
@MainActor final class ScreenTint {
    private var windows: [UInt32: NSWindow] = [:]

    func apply(ids: Set<UInt32>, level: Double, extraShade: [UInt32: Double] = [:]) {
        let shade = max(0, -level / 100)
        var visible = Set<UInt32>()
        if !ids.isEmpty && (shade > 0 || !extraShade.isEmpty) {
            for screen in NSScreen.screens {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      ids.contains(id.uint32Value) else { continue }
                let transmission = (1 - shade) * (1 - (extraShade[id.uint32Value] ?? 0))
                let opacity = 1 - transmission
                guard opacity > 0.001 else { continue }
                visible.insert(id.uint32Value)
                let window = windows[id.uint32Value] ?? NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                                                 backing: .buffered, defer: false)
                window.ignoresMouseEvents = true
                window.isReleasedWhenClosed = false
                window.hasShadow = false
                window.isOpaque = false
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                window.backgroundColor = NSColor.black.withAlphaComponent(opacity)
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows[id.uint32Value] = window
            }
        }
        for id in Set(windows.keys).subtracting(visible) { windows.removeValue(forKey: id)?.close() }
    }
}
