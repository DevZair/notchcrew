import AppKit
import IOKit.pwr_mgt

private final class AwakeClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var elapsed: TimeInterval = 10
    func advance(_ seconds: TimeInterval) {
        date.addTimeInterval(seconds)
        elapsed += seconds
    }
}

private final class AwakeDriver: OfficeAwakeAssertionDriving {
    var created: [(OfficeAwakeAssertionKind, TimeInterval)] = []
    var released: [IOPMAssertionID] = []
    var failAt: Int?
    func create(kind: OfficeAwakeAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID {
        created.append((kind, timeout))
        if created.count == failAt { throw OfficeAwakeError.assertionFailed(kIOReturnError) }
        return IOPMAssertionID(created.count)
    }
    func release(_ id: IOPMAssertionID) { released.append(id) }
}

@main
struct AwakeTests {
    static func main() throws {
        let clock = AwakeClock()
        let driver = AwakeDriver()
        let notifications = NotificationCenter()
        let awake = OfficeAwake(driver: driver, now: { clock.date }, elapsedNow: { clock.elapsed },
                                useRuntimeTimer: false, notifications: notifications)
        var changes = 0
        awake.onChange = { changes += 1 }
        precondition(awake.snapshot["active"] as? Bool == false)
        precondition(awake.snapshot["endsAt"] is NSNull)
        for invalid in [Int.min, -1, 0, 721, Int.max] {
            do { try awake.start(minutes: invalid); preconditionFailure("Invalid duration accepted") }
            catch OfficeAwakeError.invalidMinutes {} catch { preconditionFailure("Wrong validation error") }
        }
        precondition(driver.created.isEmpty)
        try awake.start(minutes: 1)
        precondition(driver.created.count == 1 && driver.created[0].0 == .system && driver.created[0].1 == 60)
        precondition(awake.snapshot["active"] as? Bool == true)
        precondition(awake.snapshot["remainingSeconds"] as? Int == 60)
        precondition(awake.snapshot["endsAt"] as? Double == 1_060)
        precondition(awake.snapshot["keepDisplayAwake"] as? Bool == false)
        clock.advance(59.2)
        precondition(awake.snapshot["remainingSeconds"] as? Int == 1)
        precondition(driver.released.isEmpty)
        clock.advance(0.8)
        awake.tick()
        precondition(driver.released == [1] && awake.snapshot["active"] as? Bool == false)
        precondition(changes == 2)
        awake.stop()
        precondition(driver.released == [1] && changes == 2)

        try awake.start(minutes: 720, keepDisplayAwake: true)
        precondition(driver.created.count == 3 && driver.created[2].0 == .display)
        precondition(driver.created[1].1 == 43_200 && driver.created[2].1 == 43_200)
        precondition(awake.snapshot["keepDisplayAwake"] as? Bool == true)
        awake.stop()
        precondition(driver.released == [1, 2, 3])

        // Replacing a running timer releases its old assertions.
        try awake.start(minutes: 1, keepDisplayAwake: true)
        try awake.start(minutes: 2)
        precondition(driver.released == [1, 2, 3, 4, 5])
        // Wake past the deadline expires immediately, even if the wall clock moved backwards.
        clock.elapsed += 121
        clock.date.addTimeInterval(-3_600)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(awake.snapshot["active"] as? Bool == false && driver.released.last == 6)

        let partial = AwakeDriver()
        partial.failAt = 2
        let failed = OfficeAwake(driver: partial, useRuntimeTimer: false, notifications: notifications)
        do { try failed.start(minutes: 1, keepDisplayAwake: true); preconditionFailure("Failure swallowed") }
        catch OfficeAwakeError.assertionFailed {} catch { preconditionFailure("Wrong driver error") }
        precondition(partial.released == [1] && failed.snapshot["active"] as? Bool == false)
        let initialFailure = AwakeDriver()
        initialFailure.failAt = 1
        let initial = OfficeAwake(driver: initialFailure, useRuntimeTimer: false, notifications: notifications)
        do { try initial.start(minutes: 1); preconditionFailure("Failure swallowed") }
        catch OfficeAwakeError.assertionFailed {} catch { preconditionFailure("Wrong driver error") }
        precondition(initialFailure.released.isEmpty && initial.snapshot["active"] as? Bool == false)

        let cleanup = AwakeDriver()
        weak var weakAwake: OfficeAwake?
        autoreleasepool {
            let temporary = OfficeAwake(driver: cleanup, notifications: notifications)
            weakAwake = temporary
            try! temporary.start(minutes: 1, keepDisplayAwake: true)
        }
        precondition(weakAwake == nil && cleanup.released == [1, 2], "Timer/observer retained controller")

        // Exercise the real run-loop timer with only fake assertions.
        let tickingClock = AwakeClock()
        let tickingDriver = AwakeDriver()
        let ticking = OfficeAwake(driver: tickingDriver, now: { tickingClock.date }, elapsedNow: { tickingClock.elapsed },
                                  notifications: notifications)
        try ticking.start(minutes: 1)
        tickingClock.advance(61)
        RunLoop.main.run(until: Date().addingTimeInterval(1.15))
        precondition(tickingDriver.released == [1] && ticking.snapshot["active"] as? Bool == false)
        print("Awake checks passed: validation, system/display separation, countdown, expiry, wake, replacement, failures, deinit, runtime timer")
    }
}
