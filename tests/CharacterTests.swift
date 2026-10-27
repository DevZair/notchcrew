import AppKit

@main
struct CharacterTests {
    static func main() {
        let roster: [[String: Any]] = [
            ["id": "reviewer", "label": "Ревьюер", "status": "resting"],
            ["id": "builder", "label": "Сборщик", "status": "working"],
            ["id": "tester", "label": "Тестировщик", "status": "waiting"],
            ["id": "analyst", "label": "Аналитик", "status": "working"]
        ]
        let active = NotchCharacter.select(snapshot: ["agents": roster])
        precondition(active.count == 3)
        precondition(active.map(\.id) == ["role:tester", "role:builder", "role:analyst"])
        precondition(active.allSatisfy { $0.status == .working || $0.status == .waiting })
        let main = NotchCharacter.select(snapshot: ["agents": [roster[0]], "general": [
            ["sessionId": "real-session", "source": "Codex", "status": "working"]
        ]])
        precondition(main.count == 2 && main[0].id == "main:Codex:real-session")
        precondition(main[1].status == .resting && main[1].status.label == "отдыхает")
        let duplicates = NotchCharacter.select(snapshot: ["agents": [roster[1], roster[1]], "general": [
            ["sessionId": "same", "source": "Codex", "status": "working"],
            ["sessionId": "same", "source": "Codex", "status": "waiting"]
        ]])
        precondition(duplicates.count == 2 && Set(duplicates.map(\.id)).count == 2)
        precondition(duplicates[0].status == .waiting)
        let lostSource = NotchCharacter.select(snapshot: ["agents": [
            ["id": "builder", "status": "unknown", "latest": ["source": "Codex"]]
        ], "general": [["sessionId": "lost", "source": "Codex", "status": "waiting"]], "sources": ["Codex": false]])
        precondition(lostSource.count == 2 && lostSource.allSatisfy { $0.status == .unknown })
        let mixed = NotchCharacter.select(snapshot: ["agents": [
            ["id": "builder", "status": "working", "latest": ["source": "Codex"]]
        ], "sources": ["Codex": false, "Claude Code": true]])
        precondition(mixed.first?.status == .working, "A role can work through a different healthy provider")
        precondition(NotchCharacter.select(snapshot: [:]).isEmpty)
        precondition(NotchCharacter.select(snapshot: ["agents": roster], limit: 0).isEmpty)
        precondition(NotchCharacter.select(snapshot: ["agents": [["label": "No identity", "status": "working"]]]).isEmpty)
        let unknown = NotchCharacter.select(snapshot: ["agents": [["id": "unclear", "status": "invalid"]]])
        precondition(unknown.first?.status == .unknown)
        let unique = NotchCharacter.select(snapshot: ["agents": [["uniqueID": "stable", "label": "Агент", "status": "resting"]]])
        precondition(unique.first?.id == "role:stable")
        let view = NotchCharacterStrip(frame: NSRect(x: 0, y: 0, width: 384, height: 64))
        view.update(main)
        view.advance(now: 0.4, visible: false)
        precondition(view.toolTip?.contains("отдыхает") == true)
        print("Character checks passed: truthful status, live priority, idle fallback, stable identity, deduplication, source loss, malformed telemetry")
    }
}
