import AppKit
import ImageIO

@main
struct MediaTests {
    static func spin(until predicate: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Timed out waiting for media state")
    }

    static func main() throws {
        let sample = #"{"type":"data","diff":false,"payload":{"title":"A synthetic song","artist":"Fixture artist","playing":true,"bundleIdentifier":"com.apple.Music","duration":120,"elapsedTime":20,"timestamp":"2026-10-28T00:00:00Z","playbackRate":1.5}}"#
        let decoded = try OfficeMediaReading.decode(Data(sample.utf8))
        let reference = ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z")!
        precondition(decoded.title == "A synthetic song" && decoded.artist == "Fixture artist" && decoded.playing)
        precondition(decoded.bundleIdentifier == "com.apple.Music" && decoded.timestamp == reference)
        precondition(decoded.elapsed(at: reference.addingTimeInterval(10), receivedAt: reference) == 35)
        precondition(decoded.elapsed(at: reference.addingTimeInterval(100), receivedAt: reference) == 120)
        var paused = decoded
        paused.playing = false
        precondition(paused.elapsed(at: reference.addingTimeInterval(100), receivedAt: reference) == 20)
        var noTimestamp = decoded
        noTimestamp.timestamp = nil
        precondition(noTimestamp.elapsed(at: reference.addingTimeInterval(10), receivedAt: reference) == 35)
        let empty = try OfficeMediaReading.decode(Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8))
        precondition(empty.title.isEmpty && !empty.playing)
        let numerical = try OfficeMediaReading.decode(Data(#"{"type":"data","diff":false,"payload":{"elapsedTime":-4,"duration":true,"timestamp":1700000000,"title":null,"playing":1}}"#.utf8))
        precondition(numerical.elapsed == 0 && numerical.duration == 0 && numerical.title.isEmpty && !numerical.playing)
        precondition(numerical.timestamp?.timeIntervalSince1970 == 1_700_000_000)
        let fractional = try OfficeMediaReading.decode(Data(#"{"type":"data","diff":false,"payload":{"timestamp":"2026-10-28T00:00:00.125Z"}}"#.utf8))
        precondition(fractional.timestamp!.timeIntervalSince(reference) == 0.125)
        for invalid in ["null", "[]", "oops", #"{"type":"data","diff":true,"payload":{}}"#, #"{"type":"data","diff":0,"payload":{}}"#, #"{"type":"data","diff":false,"payload":null}"#] {
            do { _ = try OfficeMediaReading.decode(Data(invalid.utf8)); preconditionFailure("Invalid envelope accepted") }
            catch {}
        }
        let largePayload: [String: Any] = ["type": "data", "diff": false, "payload": ["title": String(repeating: "x", count: 5_000), "artist": String(repeating: "y", count: 5_000), "bundleIdentifier": String(repeating: "z", count: 500)]]
        let bounded = try OfficeMediaReading.decode(JSONSerialization.data(withJSONObject: largePayload))
        precondition(bounded.title.count == 512 && bounded.artist.count == 512 && bounded.bundleIdentifier.count == 256)

        // Synthetic covers stay entirely in RAM; header bounds are checked before decoding.
        func png(width: Int, height: Int) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let result = NSMutableData()
            let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
            return result as Data
        }
        let syntheticCover = png(width: 512, height: 384)
        let thumbnail = OfficeMediaArtwork.thumbnail(base64: syntheticCover.base64EncodedString())!
        let coverImage = NSImage(data: thumbnail)!
        precondition(coverImage.size.width <= 256 && coverImage.size.height <= 256 && thumbnail.count <= 524_288)
        precondition(OfficeMediaArtwork.thumbnail(base64: "not base64") == nil)
        precondition(OfficeMediaArtwork.thumbnail(base64: Data("text".utf8).base64EncodedString()) == nil)
        precondition(OfficeMediaArtwork.thumbnail(base64: Data(repeating: 0, count: OfficeMediaArtwork.maximumInputBytes + 1).base64EncodedString()) == nil)
        precondition(OfficeMediaArtwork.thumbnail(base64: png(width: 4097, height: 1).base64EncodedString()) == nil)
        let coveredPayload: [String: Any] = ["type": "data", "diff": false, "payload": ["title": "Synthetic cover", "bundleIdentifier": "com.apple.Music", "artworkData": syntheticCover.base64EncodedString(), "artworkMimeType": "image/png"]]
        let coveredJSON = try JSONSerialization.data(withJSONObject: coveredPayload)
        let covered = try OfficeMediaReading.decode(coveredJSON)
        precondition(covered.artworkData != nil && covered.title == "Synthetic cover")

        var lines = OfficeMediaJSONLines()
        let half = sample.utf8.count / 2
        precondition(try! lines.consume(Data(sample.utf8.prefix(half))) == nil)
        precondition(try! lines.consume(Data((String(sample.dropFirst(half)) + "\n").utf8)) == decoded)
        let last = try lines.consume(Data((sample + "\n" + #"{"type":"data","diff":false,"payload":{}}"# + "\n").utf8))
        precondition(last == empty)
        do { _ = try lines.consume(Data(repeating: 65, count: OfficeMediaJSONLines.maximumBuffer + 1)); preconditionFailure("Unbounded line accepted") }
        catch OfficeMediaStreamError.oversizedData {} catch { preconditionFailure("Wrong size failure") }
        precondition(try! lines.consume(Data((sample + "\n").utf8)) == decoded)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/MediaTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func helper(_ name: String, body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let absent = OfficeMedia(helperURL: root.appendingPathComponent("missing"))
        absent.start()
        precondition(absent.snapshot["status"] as? String == "unavailable" && absent.snapshot["available"] as? Bool == false)
        precondition(!(absent.snapshot["message"] as? String ?? "").isEmpty)

        let fixture = try helper("steady", body: """
        [ "$#" = 2 ] && [ "$1" = stream ] && [ "$2" = --no-diff ] || exit 10
        [ -z "${ADAPTER_TEST_MODE+x}${MEDIAREMOTEADAPTER_TEST+x}${PERL5OPT+x}${DYLD_INSERT_LIBRARIES+x}" ] || exit 11
        printf '%s\\n' '\(sample)'
        exec /bin/sleep 30
        """)
        let oldTestMode = getenv("ADAPTER_TEST_MODE").map { String(cString: $0) }
        setenv("ADAPTER_TEST_MODE", "fixture-must-not-inherit", 1)
        defer {
            if let oldTestMode { setenv("ADAPTER_TEST_MODE", oldTestMode, 1) } else { unsetenv("ADAPTER_TEST_MODE") }
        }
        var now = reference
        let media = OfficeMedia(helperURL: fixture, now: { now })
        var updates = 0
        media.onChange = { precondition(Thread.isMainThread); updates += 1 }
        media.start()
        spin(until: { media.snapshot["available"] as? Bool == true })
        precondition(media.snapshot["title"] as? String == "A synthetic song" && media.snapshot["elapsed"] as? Double == 20)
        now.addTimeInterval(10)
        precondition(media.snapshot["elapsed"] as? Double == 35)
        precondition(media.snapshot["updatedAt"] as? Double == reference.timeIntervalSince1970)
        precondition(!(media.snapshot["app"] as? String ?? "").isEmpty)
        precondition(media.snapshot["controlsAvailable"] as? Bool == true)
        media.stop()
        precondition(media.snapshot["available"] as? Bool == false && media.snapshot["title"] as? String == "")
        let stoppedUpdates = updates
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(updates == stoppedUpdates)

        let emptyFixture = try helper("empty", body: "printf '%s\\n' '{\"type\":\"data\",\"diff\":false,\"payload\":{}}'\nexec /bin/sleep 30\n")
        let quiet = OfficeMedia(helperURL: emptyFixture)
        quiet.start()
        spin(until: { quiet.snapshot["available"] as? Bool == true })
        precondition(quiet.snapshot["playing"] as? Bool == false && quiet.snapshot["title"] as? String == "")
        precondition(quiet.snapshot["controlsAvailable"] as? Bool == false)
        quiet.stop()

        let actionLog = root.appendingPathComponent("synthetic-actions")
        let coveredText = String(data: coveredJSON, encoding: .utf8)!
        let actionFixture = try helper("actions", body: """
        [ -z "${ADAPTER_TEST_MODE+x}${MEDIAREMOTEADAPTER_TEST+x}${PERL5OPT+x}${DYLD_INSERT_LIBRARIES+x}" ] || exit 11
        if [ "$1" = stream ]; then
          [ "$#" = 2 ] && [ "$2" = --no-diff ] || exit 10
          printf '%s\\n' '\(coveredText)'
          exec /bin/sleep 30
        fi
        [ "$#" = 1 ] || exit 12
        case "$1" in previous-track|toggle-play-pause|next-track) ;; *) exit 13;; esac
        printf '%s\\n' "$1" >> '\(actionLog.path)'
        exec /bin/sleep 0.1
        """)
        let actions = OfficeMedia(helperURL: actionFixture)
        actions.perform(action: "next-track")
        precondition(!FileManager.default.fileExists(atPath: actionLog.path))
        actions.start()
        spin(until: { actions.snapshot["controlsAvailable"] as? Bool == true })
        precondition(actions.snapshot["artworkData"] as? Data != nil)
        actions.perform(action: "next-track; touch injected")
        precondition(!FileManager.default.fileExists(atPath: actionLog.path))
        precondition(!(actions.snapshot["message"] as? String ?? "").isEmpty)
        actions.perform(action: "previous-track")
        actions.perform(action: "previous-track")
        actions.perform(action: "next-track")
        actions.perform(action: "next-track")
        spin(until: { actions.snapshot["controlBusy"] as? Bool == false })
        precondition(try! String(contentsOf: actionLog, encoding: .utf8) == "previous-track\nnext-track\n", "Duplicate actions were not coalesced")
        actions.perform(action: "toggle-play-pause")
        spin(until: { actions.snapshot["controlBusy"] as? Bool == false })
        precondition(try! String(contentsOf: actionLog, encoding: .utf8) == "previous-track\nnext-track\ntoggle-play-pause\n")
        actions.stop()
        precondition(actions.snapshot["artworkData"] == nil && actions.snapshot["controlsAvailable"] as? Bool == false)

        let errorFixture = try helper("action-failure", body: "if [ \"$1\" = stream ]; then\nprintf '%s\\n' '\(sample)'\nexec /bin/sleep 30\nfi\nexit 9\n")
        let errors = OfficeMedia(helperURL: errorFixture)
        errors.start()
        spin(until: { errors.snapshot["controlsAvailable"] as? Bool == true })
        errors.perform(action: "toggle-play-pause")
        spin(until: { errors.snapshot["controlBusy"] as? Bool == false })
        precondition((errors.snapshot["message"] as? String ?? "").contains("Не удалось"))
        errors.stop()

        let actionPID = root.appendingPathComponent("action-pid")
        let slowFixture = try helper("action-timeout", body: "if [ \"$1\" = stream ]; then\nprintf '%s\\n' '\(sample)'\nexec /bin/sleep 30\nfi\nprintf '%s' \"$$\" > '\(actionPID.path)'\nexec /bin/sleep 30\n")
        let slow = OfficeMedia(helperURL: slowFixture, controlTimeout: 0.1)
        slow.start()
        spin(until: { slow.snapshot["controlsAvailable"] as? Bool == true })
        slow.perform(action: "next-track")
        slow.perform(action: "previous-track")
        spin(until: { slow.snapshot["controlBusy"] as? Bool == false })
        precondition((slow.snapshot["message"] as? String ?? "").contains("не ответило"))
        let timedOutPID = Int32(try String(contentsOf: actionPID, encoding: .utf8))!
        spin(until: { Darwin.kill(timedOutPID, 0) != 0 })
        slow.perform(action: "toggle-play-pause")
        spin(until: { (try? String(contentsOf: actionPID, encoding: .utf8)) != String(timedOutPID) })
        let stoppedPID = Int32(try String(contentsOf: actionPID, encoding: .utf8))!
        slow.stop()
        spin(until: { Darwin.kill(stoppedPID, 0) != 0 })
        precondition(slow.snapshot["controlBusy"] as? Bool == false)
        weak var weakControllingMedia: OfficeMedia?
        var releasedControlPID: Int32 = 0
        autoreleasepool {
            let transient = OfficeMedia(helperURL: slowFixture)
            weakControllingMedia = transient
            transient.start()
            spin(until: { transient.snapshot["controlsAvailable"] as? Bool == true })
            transient.perform(action: "next-track")
            spin(until: { (try? String(contentsOf: actionPID, encoding: .utf8)) != String(stoppedPID) })
            releasedControlPID = Int32(try! String(contentsOf: actionPID, encoding: .utf8))!
        }
        precondition(weakControllingMedia == nil, "Control process retained media service")
        spin(until: { Darwin.kill(releasedControlPID, 0) != 0 })

        let attempts = root.appendingPathComponent("attempts")
        let failingFixture = try helper("failing", body: "printf x >> '\(attempts.path)'\nprintf '%s\\n' '\(sample)'\n/bin/sleep 0.1\nexit 1\n")
        let failing = OfficeMedia(helperURL: failingFixture, retryDelays: [0.02, 0.02])
        failing.start()
        spin(until: { failing.snapshot["status"] as? String == "unavailable" })
        precondition(try! String(contentsOf: attempts, encoding: .utf8) == "xxx")
        precondition(failing.snapshot["available"] as? Bool == false && failing.snapshot["title"] as? String == "")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(try! String(contentsOf: attempts, encoding: .utf8) == "xxx", "Retry budget reset itself")
        failing.start()
        spin(until: { failing.snapshot["available"] as? Bool == true })
        failing.stop()
        precondition(try! String(contentsOf: attempts, encoding: .utf8) == "xxxx")

        weak var weakMedia: OfficeMedia?
        autoreleasepool {
            let transient = OfficeMedia(helperURL: fixture)
            weakMedia = transient
            transient.start()
        }
        precondition(weakMedia == nil, "Process callback retained media service")
        print("Media checks passed: JSONL, schema, cover bounds, timestamps, progress, helper lifecycle, environment, retry cap, playback allowlist/coalescing/errors/timeouts/cleanup, restart")
    }
}
