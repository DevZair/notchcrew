import AppKit

/// In-memory AppKit journey checks. Never creates a window, sleep assertion or media process.
@main
struct MiniViewTests {
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    static func button(_ view: NSView, _ label: String) -> NSButton {
        guard let result = descendants(view).compactMap({ $0 as? NSButton }).first(where: {
            $0.accessibilityLabel() == label || $0.toolTip == label || $0.title == label
        }) else { fatalError("Missing button: \(label)") }
        return result
    }
    static func displaySwitch(_ view: NSView) -> NSSwitch {
        guard let result = descendants(view).compactMap({ $0 as? NSSwitch }).first(where: {
            $0.accessibilityLabel() == "Держать экран включённым"
        }) else { fatalError("Missing display-awake switch") }
        return result
    }
    static func labels(_ view: NSView) -> [String] {
        descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
    }
    static func click(_ view: NSView, _ label: String) {
        let control = button(view, label)
        precondition(control.isEnabled, "Expected enabled button: \(label)")
        control.performClick(nil)
    }
    static func select(_ view: NotchMiniView, _ label: String, height: CGFloat) {
        click(view, label)
        precondition(view.desiredHeight == height, "Wrong height for \(label)")
        precondition(button(view, label).accessibilityValue() as? String == "Выбрано")
        let selected = descendants(view).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityValue() as? String == "Выбрано"
        }
        precondition(selected.count == 1, "Exactly one navigation tab must be selected")
    }
    static func main() {
        precondition(Thread.isMainThread)
        _ = NSApplication.shared
        let view = NotchMiniView(frame: NSRect(x: 0, y: 0, width: 490, height: 198))
        var openedOffice = 0, openedRequests = 0, awakeStopped = 0
        var awakeStarted: [(Int, Bool)] = []
        var mediaActions: [String] = [], heights: [CGFloat] = []
        view.onOpenOffice = { openedOffice += 1 }
        view.onOpenRequests = { openedRequests += 1 }
        view.onAwakeStart = { awakeStarted.append(($0, $1)) }
        view.onAwakeStop = { awakeStopped += 1 }
        view.onMediaAction = { mediaActions.append($0) }
        view.onHeightChange = { heights.append($0) }
        let tabs = ["Заметки", "Медиа", "Задачи", "Офис агентов", "Не давать Mac уснуть", "Буфер обмена"]
        for (index, label) in tabs.enumerated() {
            precondition(button(view, label).tag == index, "Navigation order must match the reference")
        }
        view.layoutSubtreeIfNeeded()
        let tabFrames = tabs.map { button(view, $0).frame }
        precondition(tabFrames.allSatisfy { $0.minX >= 10 && $0.maxX <= 150 }, "Six tabs must stay in the left wing, clear of the physical notch")
        for index in 1..<tabFrames.count {
            precondition(tabFrames[index - 1].maxX < tabFrames[index].minX, "Navigation hit targets must not overlap")
        }
        precondition(view.desiredHeight == 148)
        click(view, "Открыть офис")
        precondition(openedOffice == 1)
        precondition(!descendants(view).compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Ответить:") })
        view.update(snapshot: [
            "counts": ["working": 2],
            "agents": [["id": "reviewer", "label": "Ревьюер", "status": "waiting"]],
            "general": [["sessionId": "task", "source": "Codex", "title": "Настоящая задача", "project": "Локальный проект", "status": "working"]],
            "requests": [["id": "permission-request"]]
        ])
        click(view, "Ответить: 1")
        precondition(openedRequests == 1 && labels(view).contains("Работают: 2"))
        select(view, "Задачи", height: 170)
        precondition(labels(view).contains("Настоящая задача"))
        precondition(labels(view).contains("Ревьюер"))
        precondition(labels(view).contains { $0.contains("Локальный проект") && $0.contains("работает") })
        view.update(snapshot: [:])
        precondition(labels(view).contains("Пока нет активных задач"))
        select(view, "Заметки", height: 190)
        precondition(descendants(view).contains { ($0 as? NSTextView)?.accessibilityLabel() == "Локальные заметки" })
        precondition(labels(view).contains("Только на этом Mac"))
        // Reading the scratchpad does not edit it or write UserDefaults.
        select(view, "Не давать Mac уснуть", height: 198)
        click(view, "Включить")
        precondition(awakeStarted.count == 1 && awakeStarted[0].0 == 60 && !awakeStarted[0].1)
        for (preset, minutes) in [("30 м", 30), ("1 ч", 60), ("2 ч", 120)] {
            click(view, preset)
            click(view, "Включить")
            precondition(awakeStarted.last?.0 == minutes && awakeStarted.last?.1 == false)
        }
        let display = displaySwitch(view)
        precondition(display.isEnabled && display.state == .off)
        display.performClick(nil)
        click(view, "Включить")
        precondition(awakeStarted.last?.0 == 120 && awakeStarted.last?.1 == true)
        view.updateUtilities(snapshot: ["awake": ["active": true, "remainingSeconds": 90, "keepDisplayAwake": false]])
        precondition(!displaySwitch(view).isEnabled)
        precondition(displaySwitch(view).state == .off)
        precondition(labels(view).contains("Осталось 1:30"))
        click(view, "Выключить")
        precondition(awakeStopped == 1)
        view.updateUtilities(snapshot: ["awake": ["active": false]])
        precondition(displaySwitch(view).isEnabled)
        select(view, "Медиа", height: 148)
        let transport = ["Предыдущий трек", "Воспроизвести или приостановить", "Следующий трек"]
        for name in transport {
            let control = button(view, name)
            precondition(!control.isEnabled)
            control.performClick(nil)
        }
        precondition(mediaActions.isEmpty, "Disabled controls must never invoke playback")
        precondition(labels(view).contains("Ничего не воспроизводится"))
        let media: [String: Any] = ["available": true, "controlsAvailable": false, "playing": false, "title": "Тестовое видео", "artist": "Автор", "app": "Google Chrome", "duration": 8844, "elapsed": 5491]
        view.updateUtilities(snapshot: ["media": media])
        precondition(labels(view).contains("Тестовое видео") && labels(view).contains("Google Chrome"))
        precondition(labels(view).contains("91:31") && labels(view).contains("−55:53"))
        for name in transport { precondition(!button(view, name).isEnabled) }
        var controlled = media
        controlled["controlsAvailable"] = true
        view.updateUtilities(snapshot: ["media": controlled])
        for name in transport { click(view, name) }
        precondition(mediaActions == ["previous-track", "toggle-play-pause", "next-track"], "Only allowlisted transport actions may reach the controller")
        controlled["available"] = false
        view.updateUtilities(snapshot: ["media": controlled])
        for name in transport {
            precondition(!button(view, name).isEnabled)
            button(view, name).performClick(nil)
        }
        precondition(mediaActions.count == 3)
        select(view, "Офис агентов", height: 148)
        precondition(heights == [170, 190, 198, 148], "Height callbacks fire only when the selected tab changes height")
        view.showClipboardTab()
        precondition(view.desiredHeight == 290)
        precondition(labels(view).contains("Копируйте текст или картинки"))
        precondition(!button(view, "Очистить").isEnabled)
        var copied: UUID?, removed: UUID?, paused: Bool?, cleared = false
        view.onClipboardCopy = { copied = $0; return true }
        view.onClipboardRemove = { removed = $0 }
        view.onClipboardPause = { paused = $0 }
        view.onClipboardClear = { cleared = true }
        let firstID = UUID()
        let rows = (0..<35).map { index in
            OfficeClipboard.Entry(id: index == 0 ? firstID : UUID(), text: "Тестовая запись \(index)", date: Date(timeIntervalSince1970: Double(index)))
        }
        view.updateClipboard(entries: rows, isPaused: false)
        precondition(labels(view).contains("Записей: 30"), "The native list must bound rendered history")
        let copyRows = descendants(view).compactMap { $0 as? NSButton }.filter { $0.toolTip == "Скопировать запись" }
        precondition(copyRows.count == 30)
        copyRows[0].performClick(nil)
        precondition(copied == firstID && labels(view).contains("Скопировано"))
        click(view, "Удалить запись 1")
        precondition(removed == firstID)
        click(view, "Пауза")
        precondition(paused == true)
        view.updateClipboard(entries: rows, isPaused: true)
        precondition(labels(view).contains("На паузе"))
        click(view, "Продолжить")
        precondition(paused == false)
        click(view, "Очистить")
        precondition(cleared)
        view.updateClipboard(entries: [], isPaused: false)
        precondition(!button(view, "Очистить").isEnabled)
        view.onClipboardCopy = { _ in false }
        view.updateClipboard(entries: Array(rows.prefix(1)), isPaused: false)
        button(view, "Скопировать запись").performClick(nil)
        precondition(labels(view).contains("Не удалось скопировать запись"))
        let imageID = UUID()
        let syntheticBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32)!
        let syntheticPNG = syntheticBitmap.representation(using: .png, properties: [:])!
        let imageRow = OfficeClipboard.Entry(id: imageID, text: "", date: Date(), imageData: syntheticPNG, thumbnailData: syntheticPNG, imageWidth: 100, imageHeight: 50)
        view.onClipboardCopy = { copied = $0; return true }
        view.updateClipboard(entries: [imageRow, rows[0]], isPaused: false)
        precondition(labels(view).contains("Записей: 2"))
        let imageButton = button(view, "Изображение · 100 × 50")
        precondition(imageButton.image?.size == NSSize(width: 52, height: 26) && imageButton.frame.height == 54)
        imageButton.performClick(nil)
        precondition(copied == imageID)
        view.updateClipboard(entries: [imageRow], isPaused: false, error: "Тестовая ошибка сохранения")
        precondition(labels(view).contains("Тестовая ошибка сохранения"), "Storage errors take priority over copy feedback")
        view.updateClipboard(entries: [], isPaused: false, error: "Тестовая ошибка загрузки")
        precondition(button(view, "Очистить").isEnabled, "An empty corrupt history can be cleared to recover")
        view.updateClipboard(entries: [], isPaused: false)
        // The final user action clears stale success messages and exposes the persistence notice.
        click(view, "Пауза")
        view.updateClipboard(entries: [], isPaused: true)
        precondition(labels(view).contains("История сохраняется на этом Mac"))
        precondition(heights.last == 290)
        print("Mini view checks passed: six tabs, clipboard copy/delete/clear/pause callbacks and bounded text rows, sizing, real telemetry, office/requests callbacks, awake presets/display/stop, disabled media safety and allowlisted transport callbacks")
    }
}
