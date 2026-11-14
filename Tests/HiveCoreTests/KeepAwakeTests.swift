import Foundation
import Testing
@testable import HiveCore

@Suite struct KeepAwakeTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func offNeverHoldsTheMacAwake() {
        #expect(!KeepAwakePolicy.shouldStayAwake(mode: .off, working: 3, needsYou: 1, now: Self.now, until: nil))
    }

    @Test func alwaysHoldsItAwakeEvenWhenEverythingIsIdle() {
        #expect(KeepAwakePolicy.shouldStayAwake(mode: .always, working: 0, needsYou: 0, now: Self.now, until: nil))
    }

    @Test func whileWorkingFollowsTheSessions() {
        #expect(!KeepAwakePolicy.shouldStayAwake(mode: .whileWorking, working: 0, needsYou: 0, now: Self.now, until: nil))
        #expect(KeepAwakePolicy.shouldStayAwake(mode: .whileWorking, working: 1, needsYou: 0, now: Self.now, until: nil))
        #expect(KeepAwakePolicy.shouldStayAwake(mode: .whileWorking, working: 0, needsYou: 2, now: Self.now, until: nil))
    }

    @Test func oneHourStopsAtItsEnd() {
        let until = KeepAwakePolicy.oneHourFrom(Self.now)
        #expect(until == Self.now.addingTimeInterval(3600))
        #expect(KeepAwakePolicy.shouldStayAwake(mode: .oneHour, working: 0, needsYou: 0, now: Self.now, until: until))
        #expect(!KeepAwakePolicy.shouldStayAwake(mode: .oneHour, working: 0, needsYou: 0, now: until, until: until))
        #expect(!KeepAwakePolicy.shouldStayAwake(mode: .oneHour, working: 0, needsYou: 0, now: Self.now, until: nil))
        #expect(KeepAwakePolicy.expired(mode: .oneHour, now: until, until: until))
        #expect(!KeepAwakePolicy.expired(mode: .always, now: until, until: until))
    }

    @Test func minutesLeftRoundsUpAndNeverGoesNegative() {
        let until = Self.now.addingTimeInterval(3600)
        #expect(KeepAwakePolicy.minutesLeft(now: Self.now, until: until) == 60)
        #expect(KeepAwakePolicy.minutesLeft(now: Self.now.addingTimeInterval(3540.5), until: until) == 1)
        #expect(KeepAwakePolicy.minutesLeft(now: until.addingTimeInterval(10), until: until) == 0)
    }

    @Test func unknownStoredValuesFallBackToOff() {
        #expect(KeepAwakeMode(stored: "whileWorking") == .whileWorking)
        #expect(KeepAwakeMode(stored: "nonsense") == .off)
        #expect(KeepAwakeMode(stored: nil) == .off)
    }
}
