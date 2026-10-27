import AppKit

/// Compact, native notch surface. Telemetry and actions are supplied by the app controller.
final class NotchMiniView: NSView, NSTextViewDelegate {
    var onOpenOffice: () -> Void = {}
    var onOpenRequests: () -> Void = {}
    var onAwakeStart: (Int, Bool) -> Void = { _, _ in }
    var onAwakeStop: () -> Void = {}
    var onMediaAction: (String) -> Void = { _ in }
    var onClipboardCopy: (UUID) -> Bool = { _ in false }
    var onClipboardRemove: (UUID) -> Void = { _ in }
    var onClipboardClear: () -> Void = {}
    var onClipboardPause: (Bool) -> Void = { _ in }
    var onHeightChange: ((CGFloat) -> Void)?
    private(set) var desiredHeight: CGFloat = 148

    private enum Tab: Int, CaseIterable { case notes, media, tasks, office, awake, clipboard }
    private var selected: Tab = .office
    private var snapshot: [String: Any] = [:]
    private var utilities: [String: Any] = [:]
    private var clipboardEntries: [OfficeClipboard.Entry] = []
    private var clipboardPaused = false
    private var clipboardFeedback = ""
    private var clipboardError: String?
    private var clipboardScroll: NSScrollView?
    private var clipboardScrollOffset: CGFloat = 0
    private var buttons: [NSButton] = []
    private var content: [NSView] = []
    private let summary = NSTextField(labelWithString: "")
    private let characters = NotchCharacterStrip(frame: .zero)
    private let noteEditor = NSTextView(frame: .zero)
    private var selectedMinutes = 60
    private var keepDisplay = false
    private var isUpdatingNotes = false
    private let secondary = NSColor(calibratedWhite: 0.58, alpha: 1)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(false)
        let glyphs = ["square.and.pencil", "music.note", "terminal", "building.2", "sun.max", "doc.on.clipboard"]
        let labels = ["Заметки", "Медиа", "Задачи", "Офис агентов", "Не давать Mac уснуть", "Буфер обмена"]
        for (index, glyph) in glyphs.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: glyph, accessibilityDescription: labels[index]) ?? NSImage(), target: self, action: #selector(selectTab(_:)))
            button.tag = index
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.wantsLayer = true
            button.layer?.cornerRadius = 11
            button.toolTip = labels[index]
            button.setAccessibilityLabel(labels[index])
            addSubview(button)
            buttons.append(button)
        }
        summary.font = .systemFont(ofSize: 11, weight: .semibold)
        summary.textColor = secondary
        summary.alignment = .right
        summary.lineBreakMode = .byTruncatingTail
        addSubview(summary)
        noteEditor.string = UserDefaults.standard.string(forKey: "office.notch.localNotes") ?? ""
        noteEditor.font = .systemFont(ofSize: 13)
        noteEditor.textColor = .white
        noteEditor.backgroundColor = .clear
        noteEditor.insertionPointColor = .white
        noteEditor.isRichText = false
        noteEditor.isAutomaticQuoteSubstitutionEnabled = false
        noteEditor.textContainerInset = NSSize(width: 7, height: 7)
        noteEditor.delegate = self
        noteEditor.setAccessibilityLabel("Локальные заметки")
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(snapshot: [String: Any]) {
        self.snapshot = snapshot
        characters.update(NotchCharacter.select(snapshot: snapshot, limit: 3))
        if selected == .tasks || selected == .office { rebuild() } else { refreshHeader() }
    }
    func updateUtilities(snapshot: [String: Any]) {
        utilities = snapshot
        if selected == .media || selected == .awake { rebuild() } else { refreshHeader() }
    }
    func showClipboardTab() { selected = .clipboard; rebuild() }
    func updateClipboard(entries: [OfficeClipboard.Entry], isPaused: Bool, error: String? = nil) {
        clipboardEntries = Array(entries.prefix(30))
        clipboardPaused = isPaused
        clipboardError = error
        if selected == .clipboard { rebuild() }
    }
    func advance(now: TimeInterval, visible: Bool) {
        characters.advance(now: now, visible: visible && selected == .office)
    }
    func textDidChange(_ notification: Notification) {
        guard !isUpdatingNotes else { return }
        // A local scratchpad; the app never sends its text to an agent or service.
        let limited = String(noteEditor.string.prefix(20_000))
        if limited != noteEditor.string {
            isUpdatingNotes = true
            noteEditor.string = limited
            isUpdatingNotes = false
        }
        UserDefaults.standard.set(limited, forKey: "office.notch.localNotes")
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 12 + CGFloat(index) * 23, y: 6, width: 22, height: 22)
        }
        summary.frame = NSRect(x: 337, y: 10, width: max(0, bounds.width - 357), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Concave shoulders connect the panel to the top edge, like the physical notch.
        let w = bounds.width, h = bounds.height
        let shoulder: CGFloat = 10, radius: CGFloat = 24
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: w, y: 0))
        path.curve(to: NSPoint(x: w - shoulder, y: shoulder), controlPoint1: NSPoint(x: w - shoulder, y: 0), controlPoint2: NSPoint(x: w - shoulder, y: 2))
        path.line(to: NSPoint(x: w - shoulder, y: h - radius))
        path.curve(to: NSPoint(x: w - shoulder - radius, y: h), controlPoint1: NSPoint(x: w - shoulder, y: h), controlPoint2: NSPoint(x: w - shoulder - radius, y: h))
        path.line(to: NSPoint(x: shoulder + radius, y: h))
        path.curve(to: NSPoint(x: shoulder, y: h - radius), controlPoint1: NSPoint(x: shoulder, y: h), controlPoint2: NSPoint(x: shoulder, y: h - radius))
        path.line(to: NSPoint(x: shoulder, y: shoulder))
        path.curve(to: .zero, controlPoint1: NSPoint(x: shoulder, y: 2), controlPoint2: NSPoint(x: shoulder, y: 0))
        path.close()
        path.addClip()
        let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.045, alpha: 1), ending: NSColor(calibratedWhite: 0.155, alpha: 1))!
        gradient.draw(from: .zero, to: NSPoint(x: 0, y: bounds.height), options: [])
        if selected == .media, (utilities["media"] as? [String: Any])?["available"] as? Bool == true {
            let glow = NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.22, blue: 0.22, alpha: 0), ending: NSColor(calibratedRed: 0.36, green: 0.29, blue: 0.26, alpha: 0.65))!
            glow.draw(from: .zero, to: NSPoint(x: 0, y: bounds.height), options: [])
        }
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag), tab != selected else { return }
        selected = tab
        rebuild()
    }
    private func rebuild() {
        if let scroll = clipboardScroll { clipboardScrollOffset = scroll.contentView.bounds.origin.y }
        clipboardScroll = nil
        for view in content { view.removeFromSuperview() }
        content.removeAll()
        for (index, button) in buttons.enumerated() {
            let active = index == selected.rawValue
            button.contentTintColor = active ? .white : NSColor(calibratedWhite: 0.40, alpha: 1)
            button.layer?.backgroundColor = active ? NSColor(calibratedWhite: 0.24, alpha: 1).cgColor : NSColor.clear.cgColor
            button.setAccessibilityValue(active ? "Выбрано" : "")
        }
        let height: CGFloat
        switch selected {
        case .office: height = 148; makeOffice()
        case .media: height = 148; makeMedia()
        case .tasks: height = 170; makeTasks()
        case .awake: height = 198; makeAwake()
        case .notes: height = 190; makeNotes()
        case .clipboard: height = 290; makeClipboard()
        }
        refreshHeader()
        if desiredHeight != height { desiredHeight = height; onHeightChange?(height) }
        needsLayout = true
        needsDisplay = true
    }
    private func refreshHeader() {
        let counts = snapshot["counts"] as? [String: Any] ?? [:]
        switch selected {
        case .media: summary.stringValue = (utilities["media"] as? [String: Any])?["app"] as? String ?? "Медиа"
        case .awake:
            let awake = utilities["awake"] as? [String: Any] ?? [:]
            summary.stringValue = awake["active"] as? Bool == true ? "Осталось \(clock(awake["remainingSeconds"]))" : "Выключен"
        case .notes: summary.stringValue = "Только на этом Mac"
        case .clipboard: summary.stringValue = clipboardPaused ? "На паузе" : "Записей: \(clipboardEntries.count)"
        case .office, .tasks:
            let roles = (snapshot["agents"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "working" }.count
            let general = (snapshot["general"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "working" }.count
            let working = counts["working"] as? Int ?? (roles + general)
            summary.stringValue = "Работают: \(working)"
        }
    }
    private func attach(_ view: NSView) { addSubview(view); content.append(view) }
    @discardableResult private func label(_ text: String, _ rect: NSRect, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = rect
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color ?? .white
        field.lineBreakMode = .byTruncatingTail
        attach(field)
        return field
    }
    @discardableResult private func pill(_ title: String, _ rect: NSRect, action: Selector, tag: Int = 0, selected: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = rect; button.tag = tag
        button.isBordered = false; button.wantsLayer = true
        button.layer?.cornerRadius = rect.height / 2
        button.layer?.backgroundColor = NSColor(calibratedWhite: selected ? 0.83 : 0.25, alpha: 1).cgColor
        button.contentTintColor = selected ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        attach(button)
        return button
    }
    private func makeOffice() {
        characters.frame = NSRect(x: 12, y: 44, width: 246, height: 84)
        attach(characters)
        pill("Открыть офис", NSRect(x: 361, y: 64, width: 111, height: 25), action: #selector(openOffice), selected: true)
        label("или дважды правый ⌘", NSRect(x: 354, y: 96, width: 124, height: 15), size: 9, color: secondary)
        let requests = snapshot["requests"] as? [[String: Any]] ?? []
        if !requests.isEmpty {
            pill("Ответить: \(requests.count)", NSRect(x: 361, y: 116, width: 111, height: 22), action: #selector(openRequests))
        }
    }
    private func makeTasks() {
        let general = snapshot["general"] as? [[String: Any]] ?? []
        let roles = (snapshot["agents"] as? [[String: Any]] ?? []).filter { ["working", "waiting"].contains($0["status"] as? String ?? "") }
        let rows = Array((general + roles).prefix(3))
        if rows.isEmpty {
            label("Пока нет активных задач", NSRect(x: 30, y: 67, width: 400, height: 23), size: 15, weight: .semibold)
            label("Здесь появятся реальные сессии агентов", NSRect(x: 30, y: 96, width: 400, height: 20), size: 12, color: secondary)
            return
        }
        for (index, row) in rows.enumerated() {
            let y = 35 + CGFloat(index) * 37
            let status = row["status"] as? String ?? "unknown"
            let dot = NSView(frame: NSRect(x: 29, y: y + 11, width: 6, height: 6))
            dot.wantsLayer = true; dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = (status == "waiting" ? NSColor.systemOrange : NSColor(calibratedRed: 0.58, green: 0.65, blue: 0.9, alpha: 1)).cgColor
            attach(dot)
            let latest = row["latest"] as? [String: Any] ?? [:]
            let title = nonempty(row["title"]) ?? nonempty(row["label"]) ?? nonempty(row["project"]) ?? nonempty(row["name"]) ?? "Агент Codex"
            label(title, NSRect(x: 49, y: y, width: 407, height: 20), size: 14, weight: .semibold)
            let source = nonempty(row["source"]) ?? nonempty(latest["source"]) ?? "Codex"
            let project = nonempty(row["project"]) ?? nonempty(latest["project"]) ?? ""
            let state = NotchCharacter.Status(rawValue: status)?.label ?? "нет сигнала"
            label([project, source, state].filter { !$0.isEmpty }.joined(separator: " · "), NSRect(x: 49, y: y + 21, width: 407, height: 17), size: 11, color: secondary)
        }
        label("Локальные сессии · реальные статусы", NSRect(x: 27, y: 153, width: 430, height: 14), size: 10, weight: .medium, color: secondary)
    }
    private func makeMedia() {
        let media = utilities["media"] as? [String: Any] ?? [:]
        let available = media["available"] as? Bool == true
        let art = MiniArtworkView(frame: NSRect(x: 20, y: 51, width: 67, height: 67))
        art.wantsLayer = true; art.layer?.cornerRadius = 10; art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor(calibratedWhite: 0.20, alpha: 1).cgColor
        if let data = media["artworkData"] as? Data, data.count < 5_000_000 { art.image = NSImage(data: data) }
        if art.image == nil { art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Без обложки") }
        attach(art)
        label(nonempty(media["title"]) ?? (available ? "Без названия" : "Ничего не воспроизводится"), NSRect(x: 106, y: 47, width: 353, height: 23), size: 14, weight: .semibold)
        label(nonempty(media["message"]) ?? nonempty(media["artist"]) ?? (available ? (media["playing"] as? Bool == true ? "Воспроизводится" : "На паузе") : "Откройте музыку или видео"), NSRect(x: 106, y: 70, width: 353, height: 20), size: 12, color: secondary)
        let duration = safeNumber(media["duration"])
        let elapsed = safeNumber(media["elapsed"])
        let progress = MiniProgressView(frame: NSRect(x: 106, y: 97, width: 235, height: 3))
        progress.fraction = duration > 0 ? min(1, elapsed / duration) : 0
        attach(progress)
        label(clock(elapsed), NSRect(x: 106, y: 111, width: 90, height: 16), size: 10, weight: .medium, color: secondary)
        let remaining = label(duration > 0 ? "−\(clock(max(0, duration - elapsed)))" : "", NSRect(x: 250, y: 111, width: 91, height: 16), size: 10, weight: .medium, color: secondary)
        remaining.alignment = .right
        let actions = ["previous-track", "toggle-play-pause", "next-track"]
        let glyphs = ["backward.end.fill", media["playing"] as? Bool == true ? "pause.fill" : "play.fill", "forward.end.fill"]
        let names = ["Предыдущий трек", "Воспроизвести или приостановить", "Следующий трек"]
        for index in 0..<3 {
            let button = NSButton(image: NSImage(systemSymbolName: glyphs[index], accessibilityDescription: names[index]) ?? NSImage(), target: self, action: #selector(mediaAction(_:)))
            button.frame = NSRect(x: 357 + CGFloat(index) * 36, y: 78, width: 32, height: 32)
            button.tag = index; button.identifier = NSUserInterfaceItemIdentifier(actions[index])
            button.isBordered = false; button.contentTintColor = .white
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: index == 1 ? 21 : 16, weight: .regular)
            button.setAccessibilityLabel(names[index]); button.isEnabled = available && media["controlsAvailable"] as? Bool == true
            attach(button)
        }
    }
    private func makeAwake() {
        let awake = utilities["awake"] as? [String: Any] ?? [:]
        let active = awake["active"] as? Bool == true
        let icon = NSImageView(frame: NSRect(x: 17, y: 66, width: 29, height: 29))
        icon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        icon.contentTintColor = secondary
        icon.wantsLayer = true; icon.layer?.cornerRadius = 14.5
        icon.layer?.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        attach(icon)
        label("Не дать Mac уснуть", NSRect(x: 55, y: 62, width: 320, height: 22), size: 14, weight: .semibold)
        label("Не даст Mac уснуть во время работы", NSRect(x: 55, y: 83, width: 320, height: 18), size: 11, color: secondary)
        pill(active ? "Выключить" : "Включить", NSRect(x: 389, y: 68, width: 84, height: 25), action: #selector(toggleAwake))
        label("Время", NSRect(x: 18, y: 113, width: 43, height: 18), size: 11, color: secondary)
        for (index, minutes) in [30, 60, 120].enumerated() {
            pill(["30 м", "1 ч", "2 ч"][index], NSRect(x: 61 + CGFloat(index) * 44, y: 109, width: 39, height: 23), action: #selector(chooseMinutes(_:)), tag: minutes, selected: selectedMinutes == minutes)
        }
        let monitor = NSImageView(frame: NSRect(x: 18, y: 143, width: 16, height: 16))
        monitor.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        monitor.contentTintColor = secondary
        attach(monitor)
        label("Держать экран включённым", NSRect(x: 39, y: 144, width: 183, height: 18), size: 11, weight: .medium)
        let display = NSSwitch(frame: NSRect(x: 224, y: 139, width: 38, height: 25))
        display.target = self; display.action = #selector(displayChanged(_:))
        display.state = (active ? awake["keepDisplayAwake"] as? Bool == true : keepDisplay) ? .on : .off
        display.isEnabled = !active
        display.setAccessibilityLabel("Держать экран включённым")
        display.toolTip = "Не выключать экран по бездействию"
        attach(display)
        label("Экономит батарею", NSRect(x: 352, y: 145, width: 122, height: 16), size: 10, color: secondary)
        if let error = nonempty(awake["message"]), !active {
            label(error, NSRect(x: 18, y: 173, width: 450, height: 16), size: 10, color: .systemOrange)
        } else if active { label("Осталось \(clock(awake["remainingSeconds"]))", NSRect(x: 18, y: 173, width: 400, height: 16), size: 10, color: secondary) }
    }
    private func makeNotes() {
        label("Заметки", NSRect(x: 23, y: 41, width: 420, height: 18), size: 12, weight: .semibold, color: secondary)
        let scroll = NSScrollView(frame: NSRect(x: 17, y: 66, width: 456, height: 106))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        noteEditor.frame = NSRect(x: 0, y: 0, width: 440, height: 106)
        noteEditor.minSize = NSSize(width: 0, height: 106)
        noteEditor.maxSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        noteEditor.isVerticallyResizable = true; noteEditor.isHorizontallyResizable = false
        noteEditor.textContainer?.containerSize = NSSize(width: 426, height: CGFloat.greatestFiniteMagnitude)
        noteEditor.textContainer?.widthTracksTextView = true
        scroll.documentView = noteEditor
        attach(scroll)
    }
    private func makeClipboard() {
        label("Буфер обмена", NSRect(x: 23, y: 43, width: 185, height: 22), size: 14, weight: .semibold)
        pill(clipboardPaused ? "Продолжить" : "Пауза", NSRect(x: 285, y: 42, width: 89, height: 23), action: #selector(toggleClipboardPause))
        let clear = pill("Очистить", NSRect(x: 382, y: 42, width: 84, height: 23), action: #selector(clearClipboard))
        clear.isEnabled = !clipboardEntries.isEmpty || clipboardError != nil
        if clipboardEntries.isEmpty {
            label("Копируйте текст или картинки", NSRect(x: 27, y: 123, width: 436, height: 22), size: 13, weight: .medium)
            label(clipboardPaused ? "Сбор истории сейчас приостановлен" : "Нажмите на запись, чтобы скопировать её снова", NSRect(x: 27, y: 150, width: 436, height: 20), size: 11, color: secondary)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 21, y: 76, width: 448, height: 165))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let totalHeight = clipboardEntries.reduce(CGFloat(0)) { $0 + ($1.isImage ? 69 : 51) }
            let document = MiniFlippedView(frame: NSRect(x: 0, y: 0, width: 432, height: max(165, totalHeight)))
            var y: CGFloat = 0
            for (index, entry) in clipboardEntries.enumerated() {
                let rowHeight: CGFloat = entry.isImage ? 64 : 46
                let row = NSView(frame: NSRect(x: 0, y: y, width: 430, height: rowHeight))
                row.wantsLayer = true
                row.layer?.cornerRadius = 9
                row.layer?.backgroundColor = NSColor(calibratedWhite: 0.23, alpha: 0.65).cgColor
                document.addSubview(row)
                let preview = entry.isImage ? "Изображение · \(entry.imageWidth) × \(entry.imageHeight)" : entry.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                let copy = NSButton(title: String(preview.prefix(160)), target: self, action: #selector(copyClipboardEntry(_:)))
                copy.frame = NSRect(x: 9, y: y + 5, width: 375, height: rowHeight - 10)
                if entry.isImage {
                    if let data = entry.thumbnailData, data.count <= 1_048_576, let thumbnail = NSImage(data: data), thumbnail.size.width > 0, thumbnail.size.height > 0 {
                        let scale = min(52 / thumbnail.size.width, 52 / thumbnail.size.height)
                        thumbnail.size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                        copy.image = thumbnail
                    } else {
                        copy.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
                    }
                    copy.imagePosition = .imageLeft
                    copy.imageScaling = .scaleProportionallyDown
                }
                copy.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
                copy.isBordered = false
                copy.font = .systemFont(ofSize: 12)
                copy.contentTintColor = .white
                copy.alignment = .left
                copy.lineBreakMode = .byTruncatingTail
                copy.setAccessibilityLabel("Скопировать запись \(index + 1): \(String(preview.prefix(160)))")
                copy.toolTip = "Скопировать запись"
                document.addSubview(copy)
                let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(removeClipboardEntry(_:)))
                remove.frame = NSRect(x: 393, y: y + (rowHeight - 24) / 2, width: 24, height: 24)
                remove.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
                remove.isBordered = false
                remove.contentTintColor = secondary
                remove.setAccessibilityLabel("Удалить запись \(index + 1)")
                remove.toolTip = "Удалить из истории"
                document.addSubview(remove)
                y += rowHeight + 5
            }
            scroll.documentView = document
            attach(scroll)
            let offset = min(clipboardScrollOffset, max(0, document.frame.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            clipboardScroll = scroll
        }
        let footer = clipboardError ?? (clipboardFeedback.isEmpty ? "История сохраняется на этом Mac" : clipboardFeedback)
        let footerLabel = label(footer, NSRect(x: 23, y: 251, width: 444, height: 30), size: 10, color: clipboardError == nil ? secondary : .systemOrange)
        footerLabel.maximumNumberOfLines = 2
        footerLabel.cell?.wraps = true
        footerLabel.toolTip = clipboardError
    }
    @objc private func copyClipboardEntry(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw), clipboardEntries.contains(where: { $0.id == id }) else { return }
        clipboardFeedback = onClipboardCopy(id) ? "Скопировано" : "Не удалось скопировать запись"
        rebuild()
    }
    @objc private func removeClipboardEntry(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw), clipboardEntries.contains(where: { $0.id == id }) else { return }
        clipboardFeedback = ""
        onClipboardRemove(id)
    }
    @objc private func clearClipboard() {
        clipboardFeedback = ""
        clipboardScrollOffset = 0
        onClipboardClear()
    }
    @objc private func toggleClipboardPause() {
        clipboardFeedback = ""
        onClipboardPause(!clipboardPaused)
    }
    @objc private func openOffice() { onOpenOffice() }
    @objc private func openRequests() { onOpenRequests() }
    @objc private func chooseMinutes(_ sender: NSButton) { selectedMinutes = sender.tag; rebuild() }
    @objc private func displayChanged(_ sender: NSSwitch) { keepDisplay = sender.state == .on }
    @objc private func toggleAwake() {
        if (utilities["awake"] as? [String: Any])?["active"] as? Bool == true { onAwakeStop() }
        else { onAwakeStart(selectedMinutes, keepDisplay) }
    }
    @objc private func mediaAction(_ sender: NSButton) {
        let actions = ["previous-track", "toggle-play-pause", "next-track"]
        guard actions.indices.contains(sender.tag) else { return }
        onMediaAction(actions[sender.tag])
    }
    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private func safeNumber(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
        return min(31_536_000, max(0, number.doubleValue))
    }
    private func clock(_ value: Any?) -> String {
        let seconds = Int(safeNumber(value))
        // Display elapsed minutes even for long videos (91:31).
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private final class MiniFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class MiniProgressView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.46, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Draw aspect-fill explicitly; NSImageView can replace its backing layer contents.
private final class MiniArtworkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).addClip()
        let factor = image.isTemplate ? min(bounds.width / image.size.width, bounds.height / image.size.height) * 0.45 : max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
