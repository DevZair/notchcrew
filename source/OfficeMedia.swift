import AppKit
import Darwin
import ImageIO

enum OfficeMediaArtwork {
    static let maximumInputBytes = 524_288
    static let maximumPixels = 4096
    static let thumbnailPixels = 256

    /// Validate image headers before decoding, then retain only a small PNG in RAM.
    static func thumbnail(base64: Any?) -> Data? {
        guard let encoded = base64 as? String, encoded.utf8.count <= ((maximumInputBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let format = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic"].contains(format),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= Double(maximumPixels), height.doubleValue <= Double(maximumPixels) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= thumbnailPixels, image.height <= thumbnailPixels else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumInputBytes else { return nil }
        return output as Data
    }
}

struct OfficeMediaReading: Equatable {
    var title = ""
    var artist = ""
    var bundleIdentifier = ""
    var playing = false
    var duration: Double = 0
    var elapsed: Double = 0
    var rate: Double = 1
    var timestamp: Date?
    var artworkData: Data?

    static func decode(_ data: Data) throws -> OfficeMediaReading {
        guard data.count <= OfficeMediaJSONLines.maximumBuffer else { throw OfficeMediaStreamError.oversizedData }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "data",
              let diff = envelope["diff"] as? NSNumber, CFGetTypeID(diff) == CFBooleanGetTypeID(), !diff.boolValue,
              let payload = envelope["payload"] as? [String: Any] else { throw OfficeMediaStreamError.invalidData }
        var result = OfficeMediaReading()
        result.artworkData = OfficeMediaArtwork.thumbnail(base64: payload["artworkData"])
        result.title = String((payload["title"] as? String ?? "").prefix(512))
        result.artist = String((payload["artist"] as? String ?? "").prefix(512))
        result.bundleIdentifier = String((payload["bundleIdentifier"] as? String ?? "").prefix(256))
        if let playing = payload["playing"] as? NSNumber, CFGetTypeID(playing) == CFBooleanGetTypeID() {
            result.playing = playing.boolValue
        }
        result.duration = number(payload["duration"]).map { min(31_536_000, max(0, $0)) } ?? 0
        result.elapsed = number(payload["elapsedTime"]).map { min(31_536_000, max(0, $0)) } ?? 0
        result.rate = number(payload["playbackRate"]).map { min(16, max(0, $0)) } ?? 1
        if let seconds = number(payload["timestamp"]), abs(seconds) <= 100_000_000_000 {
            result.timestamp = Date(timeIntervalSince1970: seconds)
        } else if let text = payload["timestamp"] as? String, text.count <= 64 {
            let formatter = ISO8601DateFormatter()
            result.timestamp = formatter.date(from: text)
            if result.timestamp == nil {
                formatter.formatOptions.insert(.withFractionalSeconds)
                result.timestamp = formatter.date(from: text)
            }
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    func elapsed(at date: Date, receivedAt: Date) -> Double {
        let progress = elapsed + (playing ? max(0, date.timeIntervalSince(timestamp ?? receivedAt)) * rate : 0)
        return duration > 0 ? min(duration, progress) : min(31_536_000, progress)
    }
}

enum OfficeMediaStreamError: Error { case invalidData, oversizedData, readFailed }

/// Only the latest full snapshot and its bounded cover thumbnail are retained in RAM.
struct OfficeMediaJSONLines {
    static let maximumBuffer = 1_048_576
    private var buffer = Data()

    mutating func consume(_ data: Data) throws -> OfficeMediaReading? {
        guard data.count <= Self.maximumBuffer, buffer.count <= Self.maximumBuffer - data.count else {
            buffer.removeAll(keepingCapacity: false)
            throw OfficeMediaStreamError.oversizedData
        }
        buffer.append(data)
        var latest: OfficeMediaReading?
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { latest = try OfficeMediaReading.decode(line) }
        }
        return latest
    }
}

private final class OfficeMediaPipeReader {
    private let source: DispatchSourceRead
    private let handle: FileHandle
    private var parser = OfficeMediaJSONLines()
    private let deliver: (OfficeMediaReading) -> Void
    private let fail: () -> Void
    private let deliveryLock = NSLock()
    private var pending: OfficeMediaReading?
    private var deliveryScheduled = false

    init(handle: FileHandle, deliver: @escaping (OfficeMediaReading) -> Void, fail: @escaping () -> Void) {
        self.handle = handle
        self.deliver = deliver
        self.fail = fail
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "com.devzair.notchcrew.media-read"))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        do {
            // Bound work per event, so even an unexpectedly noisy helper cannot monopolize the queue.
            for _ in 0..<8 {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count == 0 {
                    source.cancel()
                    DispatchQueue.main.async { [weak self] in self?.fail() }
                    return
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    throw OfficeMediaStreamError.readFailed
                }
                if let reading = try parser.consume(Data(bytes[0..<count])) { enqueue(reading) }
            }
        } catch {
            source.cancel()
            DispatchQueue.main.async { [weak self] in self?.fail() }
        }
    }

    private func enqueue(_ reading: OfficeMediaReading) {
        deliveryLock.lock()
        pending = reading
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        deliveryLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            let latest = self.pending
            self.pending = nil
            self.deliveryScheduled = false
            self.deliveryLock.unlock()
            if let latest { self.deliver(latest) }
        }
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }
}

/// Metadata subscriber with explicit, allowlisted playback actions.
/// All public methods and onChange run on the main thread.
final class OfficeMedia: NSObject {
    static let playbackActions: Set<String> = ["previous-track", "toggle-play-pause", "next-track"]
    private static let helperEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    var onChange: (() -> Void)?
    private let helperURL: URL?
    private let now: () -> Date
    private let retryDelays: [TimeInterval]
    private let controlTimeout: TimeInterval
    private var process: Process?
    private var reader: OfficeMediaPipeReader?
    private var retry: DispatchWorkItem?
    private var startupTimeout: DispatchWorkItem?
    private var activeExecutableURL: URL?
    private var controlProcess: Process?
    private var controlTimer: DispatchWorkItem?
    private var controlGeneration: UInt64 = 0
    private var controlAction: String?
    private var pendingAction: String?
    private var generation: UInt64 = 0
    private var attempts = 0
    private var started = false
    private var reading: OfficeMediaReading?
    private var receivedAt: Date?
    private var appName = ""
    private var status = "stopped"
    private var message = "Медиа не подключено."

    init(helperURL: URL? = nil, now: @escaping () -> Date = Date.init, retryDelays: [TimeInterval] = [1, 2], controlTimeout: TimeInterval = 3) {
        self.helperURL = helperURL
        self.now = now
        self.retryDelays = Array(retryDelays.prefix(2)).map { min(30, max(0, $0)) }
        self.controlTimeout = controlTimeout.isFinite ? min(10, max(0.1, controlTimeout)) : 3
        super.init()
    }

    var snapshot: [String: Any] {
        precondition(Thread.isMainThread)
        var result: [String: Any] = [
            "available": reading != nil,
            "playing": reading?.playing ?? false,
            "title": reading?.title ?? "",
            "artist": reading?.artist ?? "",
            "app": appName,
            "bundleIdentifier": reading?.bundleIdentifier ?? "",
            "duration": reading?.duration ?? 0,
            "elapsed": reading.map { $0.elapsed(at: now(), receivedAt: receivedAt ?? now()) } ?? 0,
            "updatedAt": receivedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "status": status,
            "message": message,
            "controlsAvailable": controlsAvailable,
            "controlBusy": controlProcess != nil,
        ]
        if let artwork = reading?.artworkData { result["artworkData"] = artwork }
        return result
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        attempts = 0
        launch()
    }

    func stop() {
        precondition(Thread.isMainThread)
        started = false
        cleanup()
        setState("stopped", message: "Медиа не подключено.")
    }

    private var controlsAvailable: Bool {
        started && status == "ready" && reading?.title.isEmpty == false && reading?.bundleIdentifier.isEmpty == false && activeExecutableURL != nil
    }

    /// Called only by an explicit UI button. Arguments never pass through a shell.
    func perform(action: String) {
        precondition(Thread.isMainThread)
        guard Self.playbackActions.contains(action) else {
            message = "Эта команда воспроизведения не поддерживается."
            onChange?()
            return
        }
        guard controlsAvailable else {
            message = "Управление появится, когда приложение передаст текущее медиа."
            onChange?()
            return
        }
        if controlProcess != nil {
            // A double click cannot accidentally toggle playback twice; at most one
            // different pending action survives a burst of button events.
            if action != controlAction { pendingAction = action }
            return
        }
        runControl(action)
    }

    private func runControl(_ action: String) {
        guard controlsAvailable, let executable = activeExecutableURL, Self.playbackActions.contains(action) else { return }
        controlGeneration &+= 1
        let current = controlGeneration
        let next = Process()
        next.executableURL = executable
        next.arguments = [action]
        next.environment = Self.helperEnvironment
        next.standardInput = FileHandle.nullDevice
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self] completed in
            let succeeded = completed.terminationStatus == 0
            DispatchQueue.main.async { [weak self] in self?.finishControl(generation: current, succeeded: succeeded) }
        }
        controlProcess = next
        controlAction = action
        message = ""
        do {
            try next.run()
            let timeout = DispatchWorkItem { [weak self] in self?.finishControl(generation: current, succeeded: false, timedOut: true) }
            controlTimer = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + controlTimeout, execute: timeout)
            onChange?()
        } catch { finishControl(generation: current, succeeded: false) }
    }

    private func finishControl(generation current: UInt64, succeeded: Bool, timedOut: Bool = false) {
        guard controlGeneration == current, controlProcess != nil else { return }
        controlGeneration &+= 1
        controlTimer?.cancel(); controlTimer = nil
        if let controlProcess { Self.terminate(controlProcess) }
        controlProcess = nil
        controlAction = nil
        let next = pendingAction
        pendingAction = nil
        if !succeeded { message = timedOut ? "Приложение не ответило на команду воспроизведения." : "Не удалось выполнить команду воспроизведения." }
        onChange?()
        if succeeded, let next { runControl(next) }
    }

    private func launch() {
        guard started else { return }
        let candidates = helperURL.map { [$0] } ?? ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"].map { URL(fileURLWithPath: $0) }
        guard let executable = candidates.first(where: { $0.isFileURL && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            started = false
            setState("unavailable", message: "Для отображения медиа нужен установленный media-control.")
            return
        }
        attempts += 1
        generation &+= 1
        let current = generation
        activeExecutableURL = executable
        setState("connecting", message: "Подключение к медиа…")
        guard started, generation == current else { return }
        let next = Process()
        let pipe = Pipe()
        next.executableURL = executable
        next.arguments = ["stream", "--no-diff"]
        // No inherited Perl, DYLD, adapter-test, or MediaRemote overrides.
        next.environment = Self.helperEnvironment
        next.standardInput = FileHandle.nullDevice
        next.standardOutput = pipe
        next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.failed(generation: current) }
        }
        process = next
        do {
            try next.run()
            try? pipe.fileHandleForWriting.close()
            reader = OfficeMediaPipeReader(handle: pipe.fileHandleForReading, deliver: { [weak self] value in
                guard let self, self.started, self.generation == current else { return }
                self.startupTimeout?.cancel()
                self.startupTimeout = nil
                self.reading = value
                self.receivedAt = self.now()
                if !value.bundleIdentifier.isEmpty,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value.bundleIdentifier) {
                    self.appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                } else { self.appName = value.bundleIdentifier }
                self.status = "ready"
                self.message = value.title.isEmpty ? "Сейчас ничего не воспроизводится." : ""
                self.onChange?()
            }, fail: { [weak self] in self?.failed(generation: current) })
            let timeout = DispatchWorkItem { [weak self] in self?.failed(generation: current) }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            failed(generation: current)
        }
    }

    private func failed(generation current: UInt64) {
        guard started, generation == current else { return }
        cleanup()
        if attempts <= retryDelays.count {
            setState("reconnecting", message: "Связь с медиа прервана. Повторное подключение…")
            let next = DispatchWorkItem { [weak self] in self?.launch() }
            retry = next
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[attempts - 1], execute: next)
        } else {
            started = false
            setState("unavailable", message: "Не удалось прочитать медиа. Повторите подключение.")
        }
    }

    private func setState(_ status: String, message: String) {
        reading = nil
        receivedAt = nil
        appName = ""
        self.status = status
        self.message = message
        onChange?()
    }

    private func cleanup() {
        generation &+= 1
        retry?.cancel(); retry = nil
        startupTimeout?.cancel(); startupTimeout = nil
        reader?.stop(); reader = nil
        controlGeneration &+= 1
        controlTimer?.cancel(); controlTimer = nil
        pendingAction = nil
        controlAction = nil
        activeExecutableURL = nil
        if let controlProcess { Self.terminate(controlProcess) }
        controlProcess = nil
        if let process { Self.terminate(process) }
        process = nil
    }

    private static func terminate(_ process: Process) {
        process.terminationHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit { cleanup() }
}
