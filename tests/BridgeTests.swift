import Foundation
import Darwin

@main struct BridgeTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requests = root.appendingPathComponent("requests")
        try fm.createDirectory(at: requests, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let id = String(repeating: "a", count: 32)
        let path = requests.appendingPathComponent("\(id).request.json")
        let reply = requests.appendingPathComponent("\(id).answer.json")
        func publish(expiry: Double = 200, question: Bool = false) throws {
            let value: [String: Any] = ["id": id, "pid": Int(getpid()), "expiresAt": expiry,
                "kind": question ? "question" : "permission", "questions": [["question": "Цвет?"]]]
            try JSONSerialization.data(withJSONObject: value).write(to: path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Unsafe reply accepted") } catch {}
        }
        let inbox = OfficeInbox(folder: root, now: {100})
        try publish()
        rejects { try inbox.answer(id: "../escape", behavior: "allow", answers: nil) }
        try inbox.answer(id: id, behavior: "deny", answers: nil)
        let answer = try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as! [String: Any]
        precondition(answer["behavior"] as? String == "deny")
        rejects { try inbox.answer(id: id, behavior: "allow", answers: nil) }
        try fm.removeItem(at: reply)
        try publish(expiry: 99)
        rejects { try inbox.answer(id: id, behavior: "allow", answers: nil) }
        try publish(question: true)
        rejects { try inbox.answer(id: id, behavior: "allow", answers: [:]) }
        try inbox.answer(id: id, behavior: "allow", answers: ["Цвет?": "Зелёный"])
        try fm.removeItem(at: reply)
        try publish()
        var bound = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        bound["input"] = ["command": "printf original"]
        let legacy = try OfficeRequestBinding.fingerprint(bound)
        bound["source"] = "Claude Code"
        let explicit = try OfficeRequestBinding.fingerprint(bound)
        precondition(explicit == legacy, "Legacy source is normalized")
        bound["source"] = "Codex"
        bound["turnId"] = "turn-original"
        bound["cwd"] = "/local/original"
        let identity = try OfficeRequestBinding.fingerprint(bound)
        for (key, value) in [("source", "Claude Code"), ("turnId", "turn-changed"), ("cwd", "/local/changed")] {
            var changed = bound
            changed[key] = value
            try JSONSerialization.data(withJSONObject: changed).write(to: path)
            rejects { try inbox.answer(id: id, behavior: "allow", answers: nil, expectedFingerprint: identity) }
            precondition(!fm.fileExists(atPath: reply.path), "Changed identity is never approved")
        }
        try JSONSerialization.data(withJSONObject: bound).write(to: path)
        let fingerprint = try OfficeRequestBinding.fingerprint(bound)
        bound["input"] = ["command": "printf changed"]
        try JSONSerialization.data(withJSONObject: bound).write(to: path)
        rejects { try inbox.answer(id: id, behavior: "allow", answers: nil, expectedFingerprint: fingerprint) }
        precondition(!fm.fileExists(atPath: reply.path), "Changed displayed request is never approved")
        let current = try OfficeRequestBinding.fingerprint(bound)
        try inbox.answer(id: id, behavior: "deny", answers: nil, expectedFingerprint: current)
        try fm.removeItem(at: reply)
        try fm.removeItem(at: path)
        let target = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try fm.createSymbolicLink(at: path, withDestinationURL: target)
        rejects { try inbox.answer(id: id, behavior: "allow", answers: nil) }
        print("Reply bridge: deny, question, expiry, duplicate, traversal and symlink checks passed.")
    }
}
