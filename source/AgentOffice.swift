import AppKit
import WebKit

final class OfficeApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusItem: NSStatusItem?
    private var collector: Process?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var buffer = Data()
    private var resources: URL?
    private var stopping = false
    private var notch: NotchController?
    private var compactPresentation = false
    private var officeVisible = true
    private var notifications: OfficeNotifications?
    private var notificationStatus = "notDetermined"
    private var requestedID: String?
    private let awake = OfficeAwake()
    private let clipboard = OfficeClipboard(storageURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchCrew/Clipboard/history.plist"))
    private var media: OfficeMedia?
    private var utilitiesTimer: Timer?
    private var awakeError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = Bundle.main.resourceURL else {
            fail("Не найдены файлы приложения."); return
        }
        self.resources = resources
        buildMenus()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchCrew")
        notifications = OfficeNotifications(folder: folder, onOpen: { [weak self] id in self?.showRequests(id: id) }, onStatus: { [weak self] status in self?.setNotificationStatus(status) })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "officeBridge")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let size = NSSize(width: min(1380, visible.width - 40), height: min(930, visible.height - 40))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "NotchCrew · агенты"
        win.minSize = NSSize(width: 1060, height: 780)
        win.backgroundColor = .black
        win.contentView = view
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        self.webView = view
        self.notch = NotchController(view: view, onWillShow: { [weak self] in
            self?.window?.orderOut(nil)
            self?.window?.contentView = nil
        }, onPresentation: { [weak self] compact in self?.setCompactPresentation(compact) }, onVisibility: { [weak self] visible in self?.setOfficeVisible(visible) }, onOpenRequests: { [weak self] in self?.openRequestsTab() }, onAwakeStart: { [weak self] minutes, display in
            do { try self?.awake.start(minutes: minutes, keepDisplayAwake: display); self?.awakeError = nil; self?.publishUtilities() }
            catch { self?.showUtilityError(error.localizedDescription) }
        }, onAwakeStop: { [weak self] in self?.awake.stop() }, onMediaAction: { [weak self] action in self?.media?.perform(action: action) }, onDetach: { [weak self] in self?.showSeparateWindow() })
        notch?.bindClipboard(clipboard)
        clipboard.start()
        let bundledMedia = resources.appendingPathComponent("MediaControl/bin/media-control")
        self.media = OfficeMedia(helperURL: FileManager.default.isExecutableFile(atPath: bundledMedia.path) ? bundledMedia : nil)
        awake.onChange = { [weak self] in self?.publishUtilities() }
        media?.onChange = { [weak self] in self?.publishUtilities() }
        media?.start()
        let utilitiesTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.publishUtilities() }
        utilitiesTimer.tolerance = 0.2
        RunLoop.main.add(utilitiesTimer, forMode: .common)
        self.utilitiesTimer = utilitiesTimer
        view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        showOffice()
    }

    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О NotchCrew", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Открыть офис", action: #selector(showOffice), keyEquivalent: "o")
        appMenu.addItem(withTitle: "Открыть отдельным окном", action: #selector(showSeparateWindow), keyEquivalent: "1")
        appMenu.addItem(withTitle: "Обновить события", action: #selector(refresh), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Ожидающие разрешения", action: #selector(showPending), keyEquivalent: "2")
        appMenu.addItem(withTitle: "Панель в чёлке", action: #selector(showMini), keyEquivalent: "4")
        appMenu.addItem(withTitle: "Буфер обмена", action: #selector(showClipboard), keyEquivalent: "3")
        appMenu.addItem(withTitle: "Не спать 30 минут", action: #selector(awakeThirtyMinutes), keyEquivalent: "")
        appMenu.addItem(withTitle: "Выключить таймер бодрствования", action: #selector(stopAwake), keyEquivalent: "")
        appMenu.addItem(withTitle: "Включить уведомления Mac…", action: #selector(enableNotifications), keyEquivalent: "")
        appMenu.addItem(withTitle: "Проверить уведомление", action: #selector(testNotification), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
        let tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray.button?.image = NSImage(systemSymbolName: "building.2.crop.circle", accessibilityDescription: "NotchCrew")
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть офис", action: #selector(showOffice), keyEquivalent: "")
        menu.addItem(withTitle: "Открыть отдельным окном", action: #selector(showSeparateWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Обновить события", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: "Ожидающие разрешения", action: #selector(showPending), keyEquivalent: "")
        menu.addItem(withTitle: "Панель в чёлке", action: #selector(showMini), keyEquivalent: "")
        menu.addItem(withTitle: "Буфер обмена", action: #selector(showClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Не спать 30 минут", action: #selector(awakeThirtyMinutes), keyEquivalent: "")
        menu.addItem(withTitle: "Выключить таймер бодрствования", action: #selector(stopAwake), keyEquivalent: "")
        menu.addItem(withTitle: "Включить уведомления Mac…", action: #selector(enableNotifications), keyEquivalent: "")
        menu.addItem(withTitle: "Проверить уведомление", action: #selector(testNotification), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        tray.menu = menu
        statusItem = tray
    }

    @objc private func showOffice() {
        window?.orderOut(nil)
        window?.contentView = nil
        notch?.showOffice()
    }

    @objc private func showPending() { showRequests(id: nil) }
    @objc private func enableNotifications() { notifications?.enable() }
    @objc private func testNotification() { notifications?.sendTest() }
    @objc private func showMini() { notch?.showMini() }
    @objc private func showClipboard() { notch?.showClipboard() }
    @objc private func awakeThirtyMinutes() {
        do { try awake.start(minutes: 30) }
        catch { showMini(); showUtilityError(error.localizedDescription) }
    }
    @objc private func stopAwake() { awake.stop() }

    private func utilitiesSnapshot() -> [String: Any] {
        var sleep = awake.snapshot
        sleep["message"] = awakeError ?? ""
        return ["awake": sleep, "media": media?.snapshot ?? ["available": false]]
    }

    private func publishUtilities() {
        notch?.updateUtilities(snapshot: utilitiesSnapshot())
    }

    private func showUtilityError(_ message: String) {
        awakeError = message
        publishUtilities()
    }

    private func showRequests(id: String?) {
        requestedID = id
        showOffice()
        openRequestsTab()
    }

    private func openRequestsTab() {
        webView?.callAsyncJavaScript("window.openOfficeRequests?.(id)", arguments: ["id": requestedID ?? ""], in: nil, in: .page) { _ in }
    }

    private func setNotificationStatus(_ status: String) {
        notificationStatus = status
        webView?.callAsyncJavaScript("window.setOfficeNotifications?.(status)", arguments: ["status": status], in: nil, in: .page) { _ in }
    }

    @objc private func showSeparateWindow() {
        guard let webView else { return }
        notch?.hideOffice()
        setCompactPresentation(false)
        webView.removeFromSuperview()
        window?.contentView = webView
        window?.makeKeyAndOrderFront(nil)
        setOfficeVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NotchCrew", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", .credits: NSAttributedString(string: "Роли из вашего локального каталога. Только локальные события.\nCodex: журналы сессий. Claude Code: хук событий и ответов.\nРеплики — шутки. Статусы — реальные события.")])
    }

    @objc private func refresh() {
        media?.stop(); media?.start()
        stopCollector()
        buffer.removeAll(keepingCapacity: true)
        startCollector()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setCompactPresentation(compactPresentation)
        setOfficeVisible(officeVisible)
        setNotificationStatus(notificationStatus)
        publishUtilities()
        startCollector()
    }

    private func setCompactPresentation(_ compact: Bool) {
        compactPresentation = compact
        webView?.callAsyncJavaScript("window.setOfficePresentation?.(compact)", arguments: ["compact": compact], in: nil, in: .page) { _ in }
    }

    private func setOfficeVisible(_ visible: Bool) {
        officeVisible = visible
        webView?.callAsyncJavaScript("window.setOfficeVisible?.(visible)", arguments: ["visible": visible], in: nil, in: .page) { _ in }
    }

    func windowWillClose(_ notification: Notification) { setOfficeVisible(false) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              url.isFileURL, let resources, url.standardizedFileURL.path == resources.appendingPathComponent("index.html").standardizedFileURL.path,
              let body = message.body as? [String: Any], let token = body["token"] as? String, token.count < 100 else { return }
        var result: [String: Any] = ["token": token]
        do {
            switch body["action"] as? String {
            case "enableNotifications": notifications?.enable()
            case "testNotification": notifications?.sendTest()
            case "reply":
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchCrew")
                guard let fingerprint = body["fingerprint"] as? String, fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw OfficeBridgeError(text: "Обновите запрос перед ответом.") }
                try OfficeInbox(folder: folder).answer(id: body["id"] as? String ?? "", behavior: body["behavior"] as? String ?? "", answers: body["answers"] as? [String: String], expectedFingerprint: fingerprint)
                result["message"] = body["behavior"] as? String == "ask" ? "Продолжите ответ в исходном интерфейсе агента." : "Ответ записан для агента."
            case "openSource":
                guard body["source"] as? String == "Codex", let id = body["sessionId"] as? String, UUID(uuidString: id) != nil,
                      let target = URL(string: "codex://threads/\(id)"), NSWorkspace.shared.open(target) else {
                    throw OfficeBridgeError(text: "Не удалось открыть чат. Перейдите в исходное приложение вручную.")
                }
            case "copySession":
                guard let id = body["sessionId"] as? String, !id.isEmpty, id.count < 200 else { throw OfficeBridgeError(text: "Нет ID сессии.") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
                result["message"] = "ID скопирован. Вернитесь в терминал исходной сессии."
            default: throw OfficeBridgeError(text: "Неизвестное действие.")
            }
            result["ok"] = true
        } catch { result["ok"] = false; result["error"] = error.localizedDescription }
        webView?.callAsyncJavaScript("window.officeActionResult(result)", arguments: ["result": result], in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let resources else {
            decisionHandler(.cancel); return
        }
        let allowed = url.isFileURL && url.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/")
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func startCollector() {
        guard collector == nil, let resources else { return }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            displayError("Не найден Python 3. Установите Python и перезапустите офис."); return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", "-u", resources.appendingPathComponent("collector.py").path]
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                self?.displayError("Ошибка чтения локальных событий. Нажмите ⌘R, чтобы подключиться снова.")
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.collector === ended, !self.stopping else { return }
                self.collector = nil
                self.displayError("Сборщик событий остановился. Нажмите ⌘R для переподключения.")
            }
        }
        collector = process; output = pipe; errorOutput = errors
        do { try process.run() }
        catch {
            collector = nil
            displayError("Не удалось запустить чтение событий: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 4 * 1024 * 1024 else {
            buffer.removeAll(); displayError("Слишком большой пакет событий."); return
        }
        var latest: Data?
        while let end = buffer.firstIndex(of: 10) {
            latest = Data(buffer[..<end])
            buffer.removeSubrange(...end)
        }
        guard let latest else { return }
        do {
            guard var snapshot = try JSONSerialization.jsonObject(with: latest) as? [String: Any] else { throw OfficeBridgeError(text: "Неверный снимок событий.") }
            var requests = snapshot["requests"] as? [[String: Any]] ?? []
            for index in requests.indices where requests[index]["interactive"] as? Bool == true {
                requests[index]["requestFingerprint"] = try OfficeRequestBinding.fingerprint(requests[index])
            }
            snapshot["requests"] = requests
            notch?.update(snapshot: snapshot)
            notifications?.update(requests: requests)
            webView?.callAsyncJavaScript("window.receiveOffice(snapshot)", arguments: ["snapshot": snapshot], in: nil, in: .page) { [weak self] result in
                if case .failure = result {
                    self?.window?.subtitle = "Не удалось обновить интерфейс · ⌘R"
                }
            }
        } catch {
            displayError("Не удалось разобрать события. Нажмите ⌘R.")
        }
    }

    private func displayError(_ message: String) {
        notch?.setUnavailable()
        notifications?.update(requests: [])
        webView?.callAsyncJavaScript("window.officeError(message)", arguments: ["message": message], in: nil, in: .page) { _ in }
    }

    private func fail(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
        NSApp.terminate(nil)
    }

    private func stopCollector() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        if let collector, collector.isRunning { collector.terminate() }
        collector = nil; output = nil; errorOutput = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        utilitiesTimer?.invalidate(); awake.stop(); media?.stop(); clipboard.stop()
        stopping = true; notifications?.stop(); notch?.stop(); stopCollector()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOffice(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AgentOfficeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = OfficeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
