import Foundation

@main
struct NotchTests {
    static func main() {
        var hotkey = CommandDoubleTap()
        precondition(!hotkey.sample(pressed: true, now: 0))
        precondition(!hotkey.sample(pressed: false, now: 0.1))
        precondition(!hotkey.sample(pressed: true, now: 0.2))
        precondition(hotkey.sample(pressed: false, now: 0.3))
        precondition(!hotkey.sample(pressed: false, now: 0.31))
        precondition(!hotkey.sample(pressed: true, now: 1))
        precondition(!hotkey.sample(pressed: false, now: 1.7))
        precondition(!hotkey.sample(pressed: true, now: 1.8))
        precondition(!hotkey.sample(pressed: false, now: 1.9))
        precondition(!hotkey.sample(pressed: true, now: 3))
        precondition(!hotkey.sample(pressed: false, now: 3.1))
        let counts = OfficeCounts(snapshot: ["agents": [
            ["status": "working"], ["status": "resting"], ["status": "waiting"], ["status": "unknown"],
        ], "general": [["status": "working"], ["status": "unknown"]]])
        precondition(counts.total == 4 && counts.working == 2 && counts.waiting == 1)
        precondition(counts.resting == 1 && counts.unknown == 1 && counts.general == 1)
        let mains = OfficeCounts(snapshot: ["agents": [["status": "resting"]],
            "general": [["status": "working"], ["status": "waiting"], ["status": "unknown"]]])
        precondition(mains.working == 1 && mains.waiting == 1 && mains.general == 2)
        let many = OfficeCounts(snapshot: ["agents": [["status": "working"]],
            "general": [["status": "working"]], "activity": ["generalWorking": 15, "generalWaiting": 2]])
        precondition(many.working == 16 && many.waiting == 2 && many.general == 17)
        let missing = OfficeCounts()
        precondition(missing.total == 0 && missing.unknown == 0 && missing.working == 0 && missing.resting == 0)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 96, width: 1512, height: 853)
        let compact = OfficeLayout.frame(screen: screen, visible: visible, top: 950, expanded: false)
        let expanded = OfficeLayout.frame(screen: screen, visible: visible, top: 950, expanded: true)
        precondition(compact.maxY == 950 && expanded.maxY == 950)
        precondition(compact.midX == screen.midX && expanded.midX == screen.midX)
        precondition(compact.width < expanded.width && compact.height < expanded.height)
        precondition(compact.minY >= visible.minY && expanded.minY >= visible.minY)
        print("Notch checks passed: double tap, hold rejection, interval, counts, missing telemetry")
    }
}
