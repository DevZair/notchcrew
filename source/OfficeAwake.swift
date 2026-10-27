import AppKit
import IOKit.pwr_mgt
import Darwin

enum OfficeAwakeAssertionKind {
    case system, display
}

protocol OfficeAwakeAssertionDriving: AnyObject {
    func create(kind: OfficeAwakeAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID
    func release(_ id: IOPMAssertionID)
}

enum OfficeAwakeError: LocalizedError {
    case invalidMinutes
    case assertionFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .invalidMinutes: return "Укажите время от 1 до 720 минут."
        case .assertionFailed(let code): return "macOS не смогла включить таймер бодрствования (\(code))."
        }
    }
}

final class OfficeAwakeSystemDriver: OfficeAwakeAssertionDriving {
    func create(kind: OfficeAwakeAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID {
        let type = kind == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: type,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey: "NotchCrew · таймер бодрствования",
            // The OS also releases the assertion if the app's run loop stalls.
            kIOPMAssertionTimeoutKey: timeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard status == kIOReturnSuccess else { throw OfficeAwakeError.assertionFailed(status) }
        return id
    }

    func release(_ id: IOPMAssertionID) { IOPMAssertionRelease(id) }
}

/// Main-thread controller. Idle-sleep assertions leave manual sleep, lid sleep,
/// screen locking, and the user's permanent power settings under macOS control.
final class OfficeAwake: NSObject {
    var onChange: (() -> Void)?
    private let driver: OfficeAwakeAssertionDriving
    private let now: () -> Date
    private let elapsedNow: () -> TimeInterval
    private let useRuntimeTimer: Bool
    private let notifications: NotificationCenter
    private var wakeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var assertionIDs: [IOPMAssertionID] = []
    private var deadline: TimeInterval?
    private var endsAt: Date?
    private var keepsDisplay = false

    override convenience init() {
        self.init(driver: OfficeAwakeSystemDriver())
    }

    init(driver: OfficeAwakeAssertionDriving,
         now: @escaping () -> Date = Date.init,
         elapsedNow: @escaping () -> TimeInterval = OfficeAwake.continuousSeconds,
         useRuntimeTimer: Bool = true,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.driver = driver
        self.now = now
        self.elapsedNow = elapsedNow
        self.useRuntimeTimer = useRuntimeTimer
        self.notifications = notifications
        super.init()
        wakeObserver = notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    // Unlike uptime, this clock includes time spent asleep and cannot be moved
    // backwards by changing the system date.
    static func continuousSeconds() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    func start(minutes: Int, keepDisplayAwake: Bool = false) throws {
        precondition(Thread.isMainThread)
        guard (1...720).contains(minutes) else { throw OfficeAwakeError.invalidMinutes }
        clear()
        let duration = TimeInterval(minutes * 60)
        do {
            assertionIDs.append(try driver.create(kind: .system, timeout: duration))
            if keepDisplayAwake {
                assertionIDs.append(try driver.create(kind: .display, timeout: duration))
            }
        } catch {
            clear()
            onChange?()
            throw error
        }
        deadline = elapsedNow() + duration
        endsAt = now().addingTimeInterval(duration)
        keepsDisplay = keepDisplayAwake
        if useRuntimeTimer {
            let nextTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer = nextTimer
            RunLoop.main.add(nextTimer, forMode: .common)
        }
        onChange?()
    }

    func stop() {
        precondition(Thread.isMainThread)
        let wasActive = deadline != nil
        clear()
        if wasActive { onChange?() }
    }

    var snapshot: [String: Any] {
        precondition(Thread.isMainThread)
        expireIfNeeded()
        let remaining = deadline.map { max(0, Int(ceil($0 - elapsedNow()))) } ?? 0
        return [
            "active": deadline != nil,
            "remainingSeconds": remaining,
            "endsAt": endsAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "keepDisplayAwake": keepsDisplay,
        ]
    }

    /// Also called after wake; injectable clocks let tests exercise expiry
    /// without creating real assertions or waiting for elapsed wall time.
    func tick() {
        precondition(Thread.isMainThread)
        guard deadline != nil else { return }
        expireIfNeeded()
        onChange?()
    }

    private func expireIfNeeded() {
        if let deadline, elapsedNow() >= deadline { clear() }
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        let oldIDs = assertionIDs
        assertionIDs.removeAll()
        deadline = nil
        endsAt = nil
        keepsDisplay = false
        for id in oldIDs { driver.release(id) }
    }

    deinit {
        timer?.invalidate()
        for id in assertionIDs { driver.release(id) }
        if let wakeObserver { notifications.removeObserver(wakeObserver) }
    }
}
