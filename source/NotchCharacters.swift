import AppKit

struct NotchCharacter: Equatable {
    enum Status: String {
        case working, waiting, resting, unknown

        var label: String {
            switch self {
            case .working: return "работает"
            case .waiting: return "ждёт вас"
            case .resting: return "отдыхает"
            case .unknown: return "нет сигнала"
            }
        }
    }

    let id: String
    let name: String
    let status: Status

    /// Only real telemetry creates working/waiting characters. Idle slots come from the roster.
    static func select(snapshot: [String: Any], limit: Int = 3) -> [NotchCharacter] {
        guard limit > 0 else { return [] }
        let sources = snapshot["sources"] as? [String: Bool] ?? [:]
        var candidates: [NotchCharacter] = []
        let agents = snapshot["agents"] as? [[String: Any]] ?? []
        for agent in agents {
            guard let identifier = nonempty(agent["uniqueID"]) ?? nonempty(agent["uniqueId"]) ?? nonempty(agent["id"]) else { continue }
            // Collector already combines every instance/provider of this role.
            let status = Status(rawValue: agent["status"] as? String ?? "") ?? .unknown
            candidates.append(NotchCharacter(id: "role:\(identifier)", name: nonempty(agent["label"]) ?? nonempty(agent["name"]) ?? identifier, status: status))
        }
        for session in snapshot["general"] as? [[String: Any]] ?? [] {
            guard let identifier = nonempty(session["uniqueID"]) ?? nonempty(session["uniqueId"]) ?? nonempty(session["sessionId"]) else { continue }
            let source = nonempty(session["source"]) ?? "Агент"
            let status = sources[source] == false ? Status.unknown : Status(rawValue: session["status"] as? String ?? "") ?? .unknown
            let project = nonempty(session["title"]) ?? nonempty(session["project"]) ?? (session["kind"] as? String == "subagent" ? "подагент" : "главный")
            candidates.append(NotchCharacter(id: "main:\(source):\(identifier)", name: "\(source) · \(project)", status: status))
        }
        // Preserve snapshot order within a status; duplicate IDs never produce duplicate people.
        let order: [Status] = [.waiting, .working, .resting, .unknown]
        var selected: [NotchCharacter] = []
        var seen = Set<String>()
        for status in order {
            for character in candidates where character.status == status && !seen.contains(character.id) {
                selected.append(character)
                seen.insert(character.id)
                if selected.count == limit { return selected }
            }
        }
        return selected
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Native, asset-free pixel sprites. The controller's existing timer drives only visible views.
final class NotchCharacterStrip: NSView {
    var showsLabels = true
    private var characters: [NotchCharacter] = []
    private var phase = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ characters: [NotchCharacter]) {
        guard self.characters != characters else { return }
        self.characters = characters
        let description = characters.map { "\($0.name): \($0.status.label)" }.joined(separator: "; ")
        toolTip = description.isEmpty ? "Ожидаем локальные статусы агентов" : description
        setAccessibilityLabel(toolTip)
        needsDisplay = true
    }

    func advance(now: TimeInterval, visible: Bool) {
        guard visible else { return }
        let next = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Int(now / 0.35) % 4
        guard next != phase else { return }
        phase = next
        if characters.contains(where: { $0.status == .working || $0.status == .waiting }) { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !characters.isEmpty else { return }
        let slotWidth = bounds.width / CGFloat(characters.count)
        for (index, character) in characters.enumerated() {
            let center = slotWidth * (CGFloat(index) + 0.5)
            let scale: CGFloat = showsLabels ? 2 : 1.5
            let origin = NSPoint(x: floor(center - 8 * scale), y: showsLabels ? 27 : floor((bounds.height - 16 * scale) / 2))
            drawCharacter(character, origin: origin, scale: scale)
            guard showsLabels else { continue }
            let rect = NSRect(x: CGFloat(index) * slotWidth + 3, y: 10, width: slotWidth - 6, height: 14)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (character.name as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            (character.status.label as NSString).draw(in: rect.offsetBy(dx: 0, dy: -13), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: statusColor(character.status), .paragraphStyle: paragraph])
        }
    }

    private func statusColor(_ status: NotchCharacter.Status) -> NSColor {
        switch status {
        case .working: return NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.63, alpha: 1)
        case .waiting: return NSColor(calibratedRed: 1, green: 0.78, blue: 0.36, alpha: 1)
        case .resting, .unknown: return .lightGray
        }
    }

    private func drawCharacter(_ character: NotchCharacter, origin: NSPoint, scale: CGFloat) {
        func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
            color.setFill()
            NSRect(x: origin.x + x * scale, y: origin.y + y * scale, width: w * scale, height: h * scale).fill()
        }
        // Stable identity colours avoid a different-looking agent on each refresh.
        let hash = character.id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let coat = NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.42, brightness: 0.84, alpha: 1)
        let skin = NSColor(calibratedRed: 0.97, green: 0.77, blue: 0.57, alpha: 1)
        let hair = NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.21, alpha: 1)
        let ink = NSColor(calibratedWhite: 0.11, alpha: 1)
        if showsLabels {
            let trousers = NSColor(calibratedWhite: 0.29, alpha: 1)
            let white = NSColor(calibratedWhite: 0.87, alpha: 1)
            block(4, 0, 4, 2, white); block(9, 0, 4, 2, white)
            block(5, 2, 3, 7, trousers); block(9, 2, 3, 7, trousers)
            block(4, 9, 9, 9, character.status == .unknown ? .darkGray : coat)
            block(2, 10, 2, 7, skin); block(13, 10, 2, 7, skin)
            block(6, 18, 6, 7, skin)
            block(5, 24, 8, 3, hair); block(5, 21, 2, 4, hair)
            block(8, 21, 1, 1, ink); block(11, 21, 1, 1, ink)
            if character.status == .working {
                block(5, 12, 7, 4, white)
                block(7, 13 + CGFloat(phase % 2), 3, 1, .darkGray)
            } else if character.status == .waiting {
                block(13, 19 + CGFloat(phase % 2), 2, 5, skin)
                block(14, 25, 2, 3, statusColor(.waiting))
            } else if character.status == .resting {
                block(13, 10, 3, 4, white)
            }
            return
        }
        block(4, 0, 3, 2, ink); block(9, 0, 3, 2, ink)
        block(4, 2, 8, 6, coat)
        block(5, 8, 6, 5, skin)
        block(4, 12, 8, 2, hair); block(4, 10, 2, 3, hair)
        block(7, 10, 1, 1, ink); block(10, 10, 1, 1, ink)
        switch character.status {
        case .working:
            block(2, 2, 12, 4, NSColor(calibratedWhite: 0.35, alpha: 1))
            block(3, 3, 10, 2, statusColor(.working))
            block(2, phase % 2 == 0 ? 6 : 5, 3, 2, skin)
            block(11, phase % 2 == 0 ? 5 : 6, 3, 2, skin)
        case .waiting:
            block(1, 6, 3, 2, skin)
            block(12, phase % 2 == 0 ? 8 : 9, 2, 4, skin)
            block(13, 13, 3, 3, statusColor(.waiting))
            block(14, 14, 1, 1, ink)
        case .resting:
            block(2, 5, 3, 2, skin); block(11, 5, 3, 2, skin)
            block(11, 4, 3, 2, NSColor(calibratedWhite: 0.85, alpha: 1))
        case .unknown:
            block(2, 5, 3, 2, skin); block(11, 5, 3, 2, skin)
            block(13, 13, 2, 1, .lightGray)
            block(14, 12, 1, 1, .lightGray)
            block(13, 10, 1, 1, .lightGray)
        }
    }
}
