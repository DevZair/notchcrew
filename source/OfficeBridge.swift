import Foundation
import Darwin
import CryptoKit

enum OfficeRequestBinding {
    static func fingerprint(_ request: [String: Any]) throws -> String {
        let keys = ["id", "pid", "sessionId", "source", "turnId", "cwd", "role", "project", "tool", "input", "kind", "questions", "createdAt", "expiresAt"]
        var decision: [String: Any] = [:]
        for key in keys { if let value = request[key] { decision[key] = value } }
        // Requests from versions before 1.5 have no source field.
        decision["source"] = request["source"] ?? "Claude Code"
        let raw = try JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys])
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
}

struct OfficeBridgeError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// The inbox belongs to this app. No shell commands or remote requests are executed here.
struct OfficeInbox {
    let folder: URL
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    func answer(id: String, behavior: String, answers: [String: String]?, expectedFingerprint: String? = nil) throws {
        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              ["allow", "deny", "ask"].contains(behavior) else {
            throw OfficeBridgeError(text: "Некорректный ответ.")
        }
        let inbox = folder.appendingPathComponent("requests", isDirectory: true)
        let info = try inbox.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isSymbolicLink != true, info.isDirectory == true else {
            throw OfficeBridgeError(text: "Недоступна папка запросов.")
        }
        let requestURL = inbox.appendingPathComponent("\(id).request.json")
        let fd = open(requestURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw OfficeBridgeError(text: "Запрос уже закрыт. Ответьте в исходном чате.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0, metadata.st_size <= 128 * 1024 else {
            throw OfficeBridgeError(text: "Файл запроса не прошёл проверку.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 128 * 1024 + 1) ?? Data()
        guard data.count <= 128 * 1024 else { throw OfficeBridgeError(text: "Запрос слишком большой.") }
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["id"] as? String == id,
              let expiry = request["expiresAt"] as? Double, expiry.isFinite, expiry > now(),
              let pid = request["pid"] as? Int, pid > 0, pid <= Int(Int32.max), kill(pid_t(pid), 0) == 0 else {
            throw OfficeBridgeError(text: "Время ожидания истекло. Ответьте в исходном чате.")
        }
        if let expectedFingerprint {
            guard try OfficeRequestBinding.fingerprint(request) == expectedFingerprint else {
                throw OfficeBridgeError(text: "Запрос изменился. Посмотрите его заново в чёлке.")
            }
        }
        var reply: [String: Any] = ["behavior": behavior]
        if request["kind"] as? String == "question", behavior == "allow" {
            guard let questions = request["questions"] as? [[String: Any]], !questions.isEmpty,
                  let answers, questions.allSatisfy({ q in
                      guard let text = q["question"] as? String, let answer = answers[text] else { return false }
                      return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.utf8.count <= 12000
                  }) else { throw OfficeBridgeError(text: "Ответьте на каждый вопрос.") }
            reply["answers"] = answers
        }
        let raw = try JSONSerialization.data(withJSONObject: reply)
        guard raw.count <= 128 * 1024 else { throw OfficeBridgeError(text: "Ответ слишком большой.") }
        // Publish a fully written reply atomically; never overwrite a previous human decision.
        let temporary = inbox.appendingPathComponent(".\(UUID().uuidString).tmp")
        let answerURL = inbox.appendingPathComponent("\(id).answer.json")
        let out = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw OfficeBridgeError(text: "Не удалось сохранить ответ.") }
        let writer = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        defer { try? writer.close(); try? FileManager.default.removeItem(at: temporary) }
        try writer.write(contentsOf: raw)
        // link() is atomic and fails if an answer already exists.
        guard link(temporary.path, answerURL.path) == 0 else {
            throw OfficeBridgeError(text: "Ответ уже передан или запрос недоступен.")
        }
    }
}
