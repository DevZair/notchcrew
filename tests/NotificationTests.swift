import Foundation
import UserNotifications

@main struct NotificationTests {
    static func main() throws {
        let id = String(repeating: "b", count: 32)
        var request: [String: Any] = ["id": id, "interactive": true, "kind": "permission", "expiresAt": 200.0, "input": ["command": "printf test"], "label": "Тест", "tool": "Bash"]
        let notice = OfficeNotice(request, now: 100)
        precondition(notice?.canAllow == true)
        precondition(notice?.fullInput.contains("printf test") == true)
        request["input"] = ["command": String(repeating: "x", count: 2000)]
        precondition(OfficeNotice(request, now: 100)?.canAllow == false, "Long requests require full review")
        request["kind"] = "question"
        precondition(OfficeNotice(request, now: 100)?.canAllow == false, "Questions need an actual answer")
        request["expiresAt"] = 100.0
        precondition(OfficeNotice(request, now: 100) == nil)
        request["expiresAt"] = 200.0; request["interactive"] = false
        precondition(OfficeNotice(request, now: 100) == nil, "Read-only Codex records must not offer approvals")
        request["interactive"] = true; request["id"] = "../invalid"
        precondition(OfficeNotice(request, now: 100) == nil)
        let categories = OfficeNotifications.categories()
        for category in categories {
            for action in category.actions {
                precondition(action.options.contains(.authenticationRequired), "Lock screen decisions require authentication")
            }
            if category.identifier != OfficeNotifications.permissionCategory {
                precondition(!category.actions.contains { $0.identifier == "ALLOW_ONCE" })
            }
        }
        precondition(categories.count == 3)
        print("Notifications: live-only input, expiry, long-command review, question handling and authenticated actions passed.")
    }
}
