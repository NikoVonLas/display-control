import AppKit
import Combine
import SwiftUI
#if ACER_UPDATES
import Sparkle
#endif

/// Preserve the opening position relative to the physical display's menu bar.
/// Global screen coordinates can change when macOS makes another display primary.
struct MenuPanelAnchor {
    let displayUUID: UUID
    let rightInset: CGFloat

    init(displayUUID: UUID, panel: CGRect, screen: CGRect) {
        self.displayUUID = displayUUID
        rightInset = screen.maxX - panel.maxX
    }

    func origin(size: CGSize, screen: CGRect, menuBarBottom: CGFloat) -> CGPoint {
        CGPoint(x: max(screen.minX, min(screen.maxX - size.width, screen.maxX - rightInset - size.width)),
                y: max(screen.minY, menuBarBottom - size.height))
    }
}

private extension NSScreen {
    var displayNumber: NSNumber? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }

    // visibleFrame can include the menu bar on a secondary display. Quartz
    // exposes its actual bounds even when that display is not the main screen.
    var menuBarBottom: CGFloat {
        if let displayNumber,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let display = CGDisplayBounds(displayNumber.uint32Value)
            let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
            for window in windows where window[kCGWindowLayer as String] as? Int == menuLevel {
                guard let values = window[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = values["X"], let y = values["Y"], let width = values["Width"], let height = values["Height"],
                      abs(x - display.minX) <= 1, abs(width - display.width) <= 1,
                      abs(y - display.minY) <= 1, height > 0, height < 100 else { continue }
                return frame.maxY - (y + height - display.minY)
            }
        }
        return min(visibleFrame.maxY, frame.maxY - max(safeAreaInsets.top, NSStatusBar.system.thickness))
    }

    var menuDisplayUUID: UUID? {
        guard let id = displayNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }
}

@MainActor
final class MenuApplicationDelegate: NSObject, NSApplicationDelegate {
    lazy var store = DisplayStore()
#if ACER_UPDATES
    let updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
#endif
    private var menu: StatusMenuController?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenuController(store: store)
#if ACER_UPDATES
        updates.startUpdater()
#endif
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusMenuController: NSObject {
    private let store: DisplayStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
    private var iconUpdates: AnyCancellable?
    private var localEvents: Any?
    private var outsideClicks: Any?
    private var anchor: MenuPanelAnchor?
    private var contentSize = CGSize.zero

    init(store: DisplayStore) {
        self.store = store
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggle)
        iconUpdates = store.$display.combineLatest(store.$currentInput).sink { [weak self] display, input in
            guard let button = self?.item.button else { return }
            if display != nil, let input {
                button.image = input == .usbC ? MenuBarIcon.mac : MenuBarIcon.pc
                button.setAccessibilityLabel(input == .usbC ? "Acer Display Control · Mac" : "Acer Display Control · второй компьютер")
            } else {
                button.image = NSImage(systemSymbolName: display == nil ? "display.trianglebadge.exclamationmark" : "display.2",
                                       accessibilityDescription: "Acer Display Control")
                button.setAccessibilityLabel("Acer Display Control")
            }
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        let content = ControlPanel(store: store, openPreferences: { [weak self] in self?.openPreferences() })
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.resize(to: size)
            }
        let host = NSHostingView(rootView: content)
        let initialSize = host.fittingSize
        host.sizingOptions = []
        panel.contentView = host
        resize(to: initialSize)
        NotificationCenter.default.addObserver(self, selector: #selector(screenLayoutChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, contentSize != size else { return }
        contentSize = size
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    @objc private func toggle() {
        if anchor != nil { dismiss(); return }
        guard let button = item.button, let window = button.window, let screen = window.screen,
              let uuid = screen.menuDisplayUUID else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let panelRect = CGRect(x: buttonRect.maxX - contentSize.width, y: 0, width: contentSize.width, height: contentSize.height)
        anchor = MenuPanelAnchor(displayUUID: uuid, panel: panelRect, screen: screen.frame)
        positionPanel()
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        store.brightnessKeys.startIfPermitted()
        store.refresh()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            dismiss()
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [clicks, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { dismiss(); return nil }
            } else if event.window !== panel && event.window !== item.button?.window && !panel.frame.contains(NSEvent.mouseLocation) {
                dismiss()
            }
            return event
        }
    }

    private func positionPanel() {
        guard let anchor, let screen = NSScreen.screens.first(where: { $0.menuDisplayUUID == anchor.displayUUID })
                ?? item.button?.window?.screen ?? NSScreen.screens.first else { return }
        let origin = anchor.origin(size: contentSize, screen: screen.frame, menuBarBottom: screen.menuBarBottom)
        let frame = CGRect(origin: origin, size: contentSize)
        if panel.frame != frame { panel.setFrame(frame, display: true); panel.invalidateShadow() }
    }

    @objc private func windowMoved() {
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    @objc private func screenLayoutChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, anchor != nil else { return }
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    private func dismiss() {
        anchor = nil
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks); self.outsideClicks = nil }
        panel.orderOut(nil)
        item.button?.highlight(false)
    }

    private func openPreferences() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        // Use the Settings command provided by the SwiftUI Settings scene.
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) else { return }
        menu.performActionForItem(at: index)
    }
}
