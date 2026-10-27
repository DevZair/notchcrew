import AppKit
import UserNotifications
import IOKit.pwr_mgt

/// Only live, interactive local requests may offer a decision in a notification.
struct OfficeNotice {
    let id: String
    let kind: String
    let label: String
    let tool: String
    let input: [String: Any]
    let expiresAt: TimeInterval
    let fullInput: String
    let fingerprint: String
    var canAllow: Bool { kind == "permission" && fullInput.count <= 1200 }

    init?(_ request: [String: Any], now: TimeInterval) {
        guard request["interactive"] as? Bool == true,
              let id = request["id"] as? String, id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              let kind = request["kind"] as? String, ["permission", "question"].contains(kind),
              let expiry = request["expiresAt"] as? Double, expiry.isFinite, expiry > now,
              let input = request["input"] as? [String: Any], JSONSerialization.isValidJSONObject(input),
              let raw = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: raw, encoding: .utf8),
              let fingerprint = try? OfficeRequestBinding.fingerprint(request) else { return nil }
        self.id = id; self.kind = kind; self.expiresAt = expiry; self.input = input; self.fullInput = text
        self.label = String((request["label"] as? String ?? "Агент").prefix(80))
        self.fingerprint = fingerprint
        self.tool = String((request["tool"] as? String ?? "Инструмент").prefix(80))
    }
}

final class OfficeNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let permissionCategory = "OFFICE_PERMISSION"
    static let reviewCategory = "OFFICE_REVIEW"
    static let questionCategory = "OFFICE_QUESTION"
    static let prefix = "office-request-"
    private let center = UNUserNotificationCenter.current()
    private let inbox: OfficeInbox
    private let onOpen: (String?) -> Void
    private let onStatus: (String) -> Void
    private var active: [String: OfficeNotice] = [:]
    private var delivered: [String: String] = [:]
    private var authorized = false
    private var wakeAssertion: IOPMAssertionID = 0

    init(folder: URL, onOpen: @escaping (String?) -> Void, onStatus: @escaping (String) -> Void) {
        self.inbox = OfficeInbox(folder: folder); self.onOpen = onOpen; self.onStatus = onStatus
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        checkAuthorization(request: false)
    }

    static func categories() -> Set<UNNotificationCategory> {
        // macOS performs authentication BEFORE delivering these actions to the app.
        let allow = UNNotificationAction(identifier: "ALLOW_ONCE", title: "Разрешить один раз", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Отклонить", options: [.authenticationRequired, .destructive])
        let open = UNNotificationAction(identifier: "OPEN", title: "Посмотреть в чёлке", options: [.authenticationRequired, .foreground])
        return Set([
            UNNotificationCategory(identifier: permissionCategory, actions: [allow, deny, open], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Агент ждёт вашего разрешения", options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: reviewCategory, actions: [open, deny], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Агент ждёт вашего разрешения", options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: questionCategory, actions: [open], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Агент ждёт вашего ответа", options: [.hiddenPreviewsShowTitle]),
        ])
    }

    func enable() { checkAuthorization(request: true) }

    private func checkAuthorization(request: Bool) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined && request {
                self.center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.authorized = granted
                        self.onStatus(error == nil ? (granted ? "enabled" : "denied") : "error")
                        self.scheduleNew()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.authorized = [.authorized, .provisional].contains(settings.authorizationStatus)
                    self.onStatus(self.authorized ? "enabled" : (settings.authorizationStatus == .denied ? "denied" : "notDetermined"))
                    self.scheduleNew()
                }
            }
        }
    }

    func update(requests: [[String: Any]]) {
        let now = Date().timeIntervalSince1970
        let notices = requests.compactMap { OfficeNotice($0, now: now) }
        var next: [String: OfficeNotice] = [:]
        for notice in notices { next[notice.id] = notice }
        let changed = Set(next.keys.filter { active[$0] != nil && active[$0]?.fingerprint != next[$0]?.fingerprint })
        let closed = Set(active.keys).subtracting(next.keys).union(changed)
        let ids = closed.map { Self.prefix + $0 }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        for id in closed { delivered.removeValue(forKey: id) }
        active = next
        setWaiting(!active.isEmpty)
        scheduleNew()
    }

    private func scheduleNew() {
        guard authorized else { return }
        for notice in active.values where delivered[notice.id] != notice.fingerprint {
            delivered[notice.id] = notice.fingerprint
            let content = UNMutableNotificationContent()
            content.title = "NotchCrew · нужен ответ"
            content.subtitle = notice.label
            if notice.kind == "question" {
                content.body = "Агент задал вопрос. Ответьте в разделе «Ждут» в чёлке."
                content.categoryIdentifier = Self.questionCategory
            } else if notice.canAllow {
                content.body = "\(notice.tool)\n\(notice.fullInput)"
                content.categoryIdentifier = Self.permissionCategory
            } else {
                content.body = "\(notice.tool): подробный запрос. Посмотрите полное действие в чёлке перед разрешением."
                content.categoryIdentifier = Self.reviewCategory
            }
            content.sound = .default
            content.threadIdentifier = "office-approvals"
            content.userInfo = ["requestId": notice.id, "requestFingerprint": notice.fingerprint]
            let request = UNNotificationRequest(identifier: Self.prefix + notice.id, content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    if self?.delivered[notice.id] == notice.fingerprint { self?.delivered.removeValue(forKey: notice.id) }
                    self?.onStatus("error")
                }
            }
        }
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "NotchCrew · проверка уведомлений"
        content.body = "Уведомления работают. Реальных запросов и разрешений в этой проверке нет."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "office-notification-test", content: content, trigger: nil)) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.onStatus("error") } }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self, response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
            guard let id = response.notification.request.content.userInfo["requestId"] as? String,
                  response.notification.request.identifier == Self.prefix + id else { self.onOpen(nil); return }
            if response.actionIdentifier == "OPEN" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onOpen(id); return
            }
            guard let notice = self.active[id], notice.expiresAt > Date().timeIntervalSince1970,
                  response.notification.request.content.userInfo["requestFingerprint"] as? String == notice.fingerprint else {
                self.onStatus("expired"); self.onOpen(id); return
            }
            let behavior: String
            if response.actionIdentifier == "ALLOW_ONCE", notice.canAllow { behavior = "allow" }
            else if response.actionIdentifier == "DENY", notice.kind == "permission" { behavior = "deny" }
            else { self.onOpen(id); return }
            do {
                try self.inbox.answer(id: id, behavior: behavior, answers: nil, expectedFingerprint: notice.fingerprint)
                self.active.removeValue(forKey: id)
                self.center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
                self.setWaiting(!self.active.isEmpty)
            } catch {
                self.onStatus("expired"); self.onOpen(id)
            }
        }
    }

    private func setWaiting(_ waiting: Bool) {
        if waiting && wakeAssertion == 0 {
            var assertion: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "NotchCrew ожидает решения пользователя" as CFString, &assertion)
            if status == kIOReturnSuccess { wakeAssertion = assertion }
        } else if !waiting && wakeAssertion != 0 {
            IOPMAssertionRelease(wakeAssertion); wakeAssertion = 0
        }
    }

    func stop() {
        let ids = active.keys.map { Self.prefix + $0 }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        active.removeAll(); delivered.removeAll()
        setWaiting(false); center.delegate = nil
    }
    deinit { if wakeAssertion != 0 { IOPMAssertionRelease(wakeAssertion) } }
}
