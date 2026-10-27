import AppKit
import CoreGraphics
import QuartzCore

struct OfficeLayout {
    static func frame(screen: NSRect, visible: NSRect, top: CGFloat, expanded: Bool) -> NSRect {
        let width = min(expanded ? 1400 : 960, screen.width - 32)
        let bottom = max(screen.minY + 10, visible.minY + 8)
        let height = min(expanded ? 849 : 592, top - bottom)
        return NSRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}

struct OfficeCounts {
    var total = 0
    var working = 0
    var waiting = 0
    var resting = 0
    var unknown = 0
    var general = 0
    var generalWorking = 0
    var generalWaiting = 0
    var requests = 0

    init(snapshot: [String: Any]? = nil) {
        guard let agents = snapshot?["agents"] as? [[String: Any]] else { return }
        total = agents.count
        unknown = 0
        for agent in agents {
            switch agent["status"] as? String {
            case "working": working += 1
            case "waiting": waiting += 1
            case "resting": resting += 1
            default: unknown += 1
            }
        }
        let sessions = snapshot?["general"] as? [[String: Any]] ?? []
        let activity = snapshot?["activity"] as? [String: Int] ?? [:]
        generalWorking = max(0, activity["generalWorking"] ?? sessions.filter { $0["status"] as? String == "working" }.count)
        generalWaiting = max(0, activity["generalWaiting"] ?? sessions.filter { $0["status"] as? String == "waiting" }.count)
        general = generalWorking + generalWaiting
        working += generalWorking
        waiting += generalWaiting
        requests = (snapshot?["requests"] as? [[String: Any]] ?? []).count
    }
}

struct CommandDoubleTap {
    private var wasPressed = false
    private var pressedAt: TimeInterval = 0
    private var previousRelease: TimeInterval?

    mutating func sample(pressed: Bool, now: TimeInterval) -> Bool {
        defer { wasPressed = pressed }
        if pressed && !wasPressed { pressedAt = now }
        guard !pressed && wasPressed else { return false }
        guard now - pressedAt <= 0.3 else { previousRelease = nil; return false }
        if let previousRelease, now - previousRelease <= 0.45 {
            self.previousRelease = nil
            return true
        }
        previousRelease = now
        return false
    }
}

final class OfficePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class NotchController: NSObject {
    private let capsule = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let peek = OfficePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let office = OfficePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let leftLabel = NSTextField(labelWithString: "▦ 0")
    private let rightLabel = NSTextField(labelWithString: "· · ·")
    private let mini = NotchMiniView(frame: .zero)
    private let leftCharacter = NotchCharacterStrip(frame: .zero)
    private let rightCharacter = NotchCharacterStrip(frame: .zero)
    private var characters: [NotchCharacter] = []
    private var lastAgentSnapshot: [String: Any] = [:]
    private var peekHeight: CGFloat { mini.desiredHeight }
    private let sharedView: NSView
    private let onDetach: () -> Void
    private let onWillShow: () -> Void
    private let onPresentation: (Bool) -> Void
    private let onVisibility: (Bool) -> Void
    private let onOpenRequests: () -> Void
    private let officeHeading = NSTextField(labelWithString: "NOTCHCREW")
    private var expandButton: NSButton?
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var counts = OfficeCounts()
    private var lastSnapshot: TimeInterval = 0
    private var doubleTap = CommandDoubleTap()
    private var tickNumber = 0
    private var mouseWasDown = false
    private var hoverSince: TimeInterval?
    private var awaySince: TimeInterval?
    private var currentScreen: NSScreen?
    private var capsuleFrame = NSRect.zero
    private var triggerFrame = NSRect.zero
    private var officeContainer: NSView?
    private var nativeHeader: NSView?
    private var peekPinned = false
    private var peekClosing = false
    private var peekGeneration = 0
    private var suppressHoverUntil: TimeInterval = 0
    private var showingOffice = false
    private var unavailable = true
    private var expandedOffice = false
    private var transitioning = false
    private var animationGeneration = 0

    init(view: NSView, onWillShow: @escaping () -> Void, onPresentation: @escaping (Bool) -> Void, onVisibility: @escaping (Bool) -> Void, onOpenRequests: @escaping () -> Void, onAwakeStart: @escaping (Int, Bool) -> Void, onAwakeStop: @escaping () -> Void, onMediaAction: @escaping (String) -> Void, onDetach: @escaping () -> Void) {
        self.sharedView = view
        self.onDetach = onDetach
        self.onWillShow = onWillShow
        self.onPresentation = onPresentation
        self.onVisibility = onVisibility
        self.onOpenRequests = onOpenRequests
        super.init()
        mini.onOpenOffice = { [weak self] in self?.showOffice() }
        mini.onOpenRequests = { [weak self] in self?.showOffice(); self?.onOpenRequests() }
        mini.onAwakeStart = onAwakeStart
        mini.onAwakeStop = onAwakeStop
        mini.onMediaAction = onMediaAction
        mini.onHeightChange = { [weak self] _ in self?.positionPeek(animated: true) }
        configurePanels()
        buildCapsule()
        buildPeek()
        buildOffice()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.showingOffice == true {
                self?.hideOffice(); return nil
            }
            return event
        }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reposition()
    }

    func bindClipboard(_ clipboard: OfficeClipboard) {
        mini.onClipboardCopy = { [weak clipboard] id in clipboard?.copy(id: id) ?? false }
        mini.onClipboardRemove = { [weak clipboard] id in clipboard?.remove(id: id) }
        mini.onClipboardClear = { [weak clipboard] in clipboard?.clear() }
        mini.onClipboardPause = { [weak clipboard] paused in clipboard?.setPaused(paused) }
        clipboard.onChange = { [weak self, weak clipboard] in
            guard let clipboard else { return }
            self?.mini.updateClipboard(entries: clipboard.entries, isPaused: clipboard.isPaused, error: clipboard.lastError)
        }
        mini.updateClipboard(entries: clipboard.entries, isPaused: clipboard.isPaused, error: clipboard.lastError)
    }

    func showClipboard() {
        mini.showClipboardTab()
        showMini()
    }

    private func configurePanels() {
        for panel in [capsule, peek, office] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.hasShadow = panel !== capsule
            panel.animationBehavior = .none
        }
        capsule.title = "NotchCrew · чёлка"
        peek.title = "NotchCrew · краткий статус"
        office.title = "NotchCrew · офис из чёлки"
        office.onEscape = { [weak self] in self?.hideOffice() }
        peek.onEscape = { [weak self] in self?.hidePeek() }
    }

    private func background(radius: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        return view
    }

    private func buildCapsule() {
        let root = background(radius: 12)
        root.layer?.backgroundColor = NSColor.black.cgColor
        for label in [leftLabel, rightLabel] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = NSColor(calibratedRed: 0.75, green: 0.87, blue: 0.67, alpha: 1)
            root.addSubview(label)
        }
        rightLabel.alignment = .right
        for strip in [leftCharacter, rightCharacter] {
            strip.showsLabels = false
            root.addSubview(strip)
        }
        let button = NSButton(title: "", target: self, action: #selector(togglePeek))
        button.isBordered = false
        button.setAccessibilityLabel("Открыть панель чёлки: агенты, медиа, заметки, таймер и буфер обмена")
        button.toolTip = "NotchCrew · наведите для статуса · дважды правый ⌘"
        button.frame = root.bounds
        button.autoresizingMask = [.width, .height]
        root.addSubview(button)
        capsule.contentView = root
    }

    private func buildPeek() {
        mini.frame = NSRect(x: 0, y: 0, width: 490, height: peekHeight)
        mini.autoresizingMask = [.width, .height]
        peek.contentView = mini
    }

    private func positionPeek(animated: Bool = false) {
        guard let screen = currentScreen else { return }
        let width = min(490, screen.frame.width - 24)
        let target = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - peekHeight, width: width, height: peekHeight)
        if animated && peek.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
                peek.animator().setFrame(target, display: true)
            }
        } else { peek.setFrame(target, display: true) }
    }

    @objc private func togglePeek() {
        if peek.isVisible { hidePeek() } else { showMini() }
    }

    func showMini() {
        if showingOffice { hideOffice() }
        peekPinned = true
        showPeek()
    }

    private func showPeek() {
        guard !showingOffice, (!peek.isVisible || peekClosing) else { return }
        peekGeneration += 1
        peekClosing = false
        positionPeek()
        let target = peek.frame
        capsule.orderOut(nil)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduce { peek.setFrame(capsuleFrame, display: false) }
        peek.alphaValue = reduce ? 1 : 0.35
        peek.orderFrontRegardless()
        if !reduce {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                peek.animator().setFrame(target, display: true)
                peek.animator().alphaValue = 1
            }
        }
    }

    private func hidePeek(animated: Bool = true) {
        peekPinned = false
        hoverSince = nil
        awaySince = nil
        suppressHoverUntil = ProcessInfo.processInfo.systemUptime + 0.5
        guard peek.isVisible else { capsule.orderFrontRegardless(); return }
        guard !peekClosing || !animated else { return }
        peekGeneration += 1
        let generation = peekGeneration
        let finish = { [weak self] in
            guard let self, self.peekGeneration == generation else { return }
            self.peek.orderOut(nil)
            self.peek.alphaValue = 1
            self.peekClosing = false
            if !self.showingOffice { self.capsule.orderFrontRegardless() }
        }
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        peekClosing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            peek.animator().setFrame(capsuleFrame, display: true)
            peek.animator().alphaValue = 0.1
        }, completionHandler: finish)
    }

    private func buildOffice() {
        let root = background(radius: 24)
        office.contentView = root
        officeContainer = root
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.black.cgColor
        let title = officeHeading
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .lightGray
        title.frame = NSRect(x: 24, y: 11, width: 500, height: 16)
        title.autoresizingMask = [.width]
        let expand = NSButton(title: "⤢", target: self, action: #selector(toggleSize))
        expand.isBordered = false
        expand.font = .systemFont(ofSize: 16)
        expand.contentTintColor = .gray
        expand.frame = NSRect(x: 838, y: 0, width: 36, height: 32)
        expand.autoresizingMask = [.minXMargin]
        expandButton = expand
        let detach = NSButton(title: "↗", target: self, action: #selector(detachOffice))
        detach.isBordered = false
        detach.font = .systemFont(ofSize: 16)
        detach.contentTintColor = .gray
        detach.frame = NSRect(x: 874, y: 0, width: 36, height: 32)
        detach.autoresizingMask = [.minXMargin]
        let close = NSButton(title: "×", target: self, action: #selector(hideOffice))
        close.isBordered = false
        close.font = .systemFont(ofSize: 19)
        close.contentTintColor = .gray
        close.frame = NSRect(x: 910, y: 0, width: 36, height: 32)
        close.autoresizingMask = [.minXMargin]
        header.frame = NSRect(x: 0, y: 0, width: 960, height: 32)
        header.autoresizingMask = [.width, .minYMargin]
        expand.setAccessibilityLabel("Развернуть офис")
        detach.setAccessibilityLabel("Открыть отдельным окном")
        close.setAccessibilityLabel("Закрыть офис")
        header.addSubview(title); header.addSubview(expand); header.addSubview(detach); header.addSubview(close)
        root.addSubview(header)
        nativeHeader = header
    }

    private func reposition() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { capsule.orderOut(nil); return }
        currentScreen = screen
        let physicalWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            physicalWidth = max(0, right.minX - left.maxX)
        } else { physicalWidth = 0 }
        // All native pixels live in the wings; the camera/notch interval stays empty.
        let width = max(240, physicalWidth + 80)
        let bandHeight = max(screen.safeAreaInsets.top, 28)
        capsuleFrame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - bandHeight, width: width, height: bandHeight)
        triggerFrame = capsuleFrame.insetBy(dx: -5, dy: -8)
        capsule.setFrame(capsuleFrame, display: true)
        let wingWidth = (width - physicalWidth) / 2
        leftLabel.isHidden = true
        rightLabel.isHidden = true
        leftLabel.frame = NSRect(x: 10, y: (bandHeight - 14) / 2, width: 40, height: 14)
        rightLabel.frame = NSRect(x: width - 50, y: (bandHeight - 14) / 2, width: 40, height: 14)
        leftCharacter.frame = NSRect(x: wingWidth - 28, y: 0, width: 24, height: bandHeight)
        rightCharacter.frame = NSRect(x: width - wingWidth + 4, y: 0, width: 24, height: bandHeight)
        positionPeek()
        capsule.orderFrontRegardless()
        if showingOffice { positionOffice(on: screen) }
    }

    private func positionOffice(on screen: NSScreen) {
        let frame = OfficeLayout.frame(screen: screen.frame, visible: screen.visibleFrame, top: capsuleFrame.minY, expanded: expandedOffice)
        office.setFrame(frame, display: true)
        layoutContent(size: frame.size)
    }

    private func layoutContent(size: NSSize) {
        nativeHeader?.frame = NSRect(x: 0, y: size.height - 32, width: size.width, height: 32)
        sharedView.frame = NSRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 32))
        sharedView.autoresizingMask = [.width, .height]
    }

    private var foldedFrame: NSRect {
        NSRect(x: capsuleFrame.midX - capsuleFrame.width / 2, y: capsuleFrame.minY - 6, width: capsuleFrame.width, height: 6)
    }

    private func animate(to frame: NSRect, opening: Bool) {
        animationGeneration += 1
        let generation = animationGeneration
        transitioning = true
        let finish = { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.transitioning = false
            if opening { self.layoutContent(size: frame.size) }
            else { self.office.orderOut(nil); self.office.alphaValue = 1 }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            office.setFrame(frame, display: true)
            office.alphaValue = 1
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = opening ? 0.34 : 0.24
                context.timingFunction = opening ? CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1) : CAMediaTimingFunction(name: .easeIn)
                office.animator().setFrame(frame, display: true)
                office.animator().alphaValue = opening ? 1 : 0.2
            }, completionHandler: finish)
        }
    }

    @objc private func toggleSize() {
        guard let screen = currentScreen else { return }
        expandedOffice.toggle()
        expandButton?.title = expandedOffice ? "↙" : "⤢"
        onPresentation(!expandedOffice)
        animate(to: OfficeLayout.frame(screen: screen.frame, visible: screen.visibleFrame, top: capsuleFrame.minY, expanded: expandedOffice), opening: true)
    }

    @objc func toggleOffice() {
        if showingOffice { hideOffice() } else { showOffice() }
    }

    func showOffice() {
        guard let screen = currentScreen, let root = officeContainer else { return }
        expandedOffice = false
        expandButton?.title = "⤢"
        onWillShow()
        hidePeek(animated: false)
        sharedView.removeFromSuperview()
        root.addSubview(sharedView)
        showingOffice = true
        onVisibility(true)
        onPresentation(!expandedOffice)
        positionOffice(on: screen)
        let target = office.frame
        office.setFrame(foldedFrame, display: false)
        office.alphaValue = 0.2
        office.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        office.makeFirstResponder(sharedView)
        capsule.orderFrontRegardless()
        animate(to: target, opening: true)
        if counts.requests > 0 { onOpenRequests() }
    }

    @objc func hideOffice() {
        showingOffice = false
        onVisibility(false)
        if office.isVisible { animate(to: foldedFrame, opening: false) }
        hidePeek(animated: false)
        hoverSince = nil
        awaySince = nil
    }

    @objc private func detachOffice() {
        hideOffice()
        sharedView.removeFromSuperview()
        onPresentation(false)
        onDetach()
    }

    func update(snapshot: [String: Any]) {
        lastAgentSnapshot = snapshot
        counts = OfficeCounts(snapshot: snapshot)
        characters = NotchCharacter.select(snapshot: snapshot)
        lastSnapshot = ProcessInfo.processInfo.systemUptime
        unavailable = false
        drawStatus()
    }

    func setUnavailable() {
        unavailable = true
        drawStatus()
    }

    func updateUtilities(snapshot: [String: Any]) {
        mini.updateUtilities(snapshot: snapshot)
    }

    private func drawStatus() {
        let displayCharacters = unavailable ? characters.map { NotchCharacter(id: $0.id, name: $0.name, status: .unknown) } : characters
        leftCharacter.update(Array(displayCharacters.prefix(1)))
        rightCharacter.update(Array(displayCharacters.dropFirst().prefix(1)))
        var displaySnapshot = lastAgentSnapshot
        if unavailable {
            for key in ["agents", "general"] {
                displaySnapshot[key] = (displaySnapshot[key] as? [[String: Any]] ?? []).map { item in
                    var value = item; value["status"] = "unknown"; return value
                }
            }
            displaySnapshot["requests"] = [[String: Any]]()
        }
        displaySnapshot["counts"] = ["working": unavailable ? 0 : counts.working, "waiting": unavailable ? 0 : counts.waiting]
        mini.update(snapshot: displaySnapshot)
        let status = unavailable ? "Нет свежего сигнала" : "Работают: \(counts.working) · Отдыхают: \(counts.resting)"
        capsule.contentView?.setAccessibilityLabel("NotchCrew. \(status)")
        officeHeading.stringValue = status
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // Query only this modifier's state; no event tap and no text capture.
        if doubleTap.sample(pressed: CGEventSource.keyState(.combinedSessionState, key: 54), now: now) { toggleOffice() }
        tickNumber += 1
        guard tickNumber % 4 == 0 else { return }
        mini.advance(now: now, visible: peek.isVisible)
        leftCharacter.advance(now: now, visible: capsule.isVisible && !showingOffice)
        rightCharacter.advance(now: now, visible: capsule.isVisible && !showingOffice)
        if !unavailable && now - lastSnapshot > 15 { setUnavailable() }
        guard !transitioning else { return }
        let pointer = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons != 0
        defer { mouseWasDown = down }
        if showingOffice {
            if down && !mouseWasDown && !office.frame.contains(pointer) && !triggerFrame.contains(pointer) { hideOffice() }
            return
        }
        if peekPinned {
            if down && !mouseWasDown && !peek.frame.contains(pointer) && !triggerFrame.contains(pointer) { hidePeek() }
            return
        }
        guard now >= suppressHoverUntil, !peekClosing else { return }
        let overTrigger = triggerFrame.contains(pointer)
        let overPeek = peek.isVisible && peek.frame.contains(pointer)
        if overTrigger || overPeek {
            awaySince = nil
            if hoverSince == nil { hoverSince = now }
            if let hoverSince, now - hoverSince > 0.16 { showPeek() }
        } else {
            hoverSince = nil
            if awaySince == nil { awaySince = now }
            if let awaySince, now - awaySince > 0.4 { hidePeek() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        [office, peek, capsule].forEach { $0.orderOut(nil) }
    }
}
