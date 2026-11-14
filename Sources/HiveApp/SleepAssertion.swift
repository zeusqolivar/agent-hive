import IOKit.pwr_mgt

/// Asks macOS not to sleep while held, the way `caffeinate -i` does: the display can still turn off.
/// macOS drops the request by itself if the app quits.
@MainActor
final class SleepAssertion {
    static let reason = "Agent Hive is keeping your Mac awake while your agents work"
    private var id: IOPMAssertionID = 0

    var isHeld: Bool { id != 0 }

    func set(_ hold: Bool) {
        if hold, id == 0 {
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     Self.reason as CFString, &newID)
            if result == kIOReturnSuccess { id = newID }
        } else if !hold, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}
