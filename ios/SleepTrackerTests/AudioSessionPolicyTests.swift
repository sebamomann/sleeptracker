import Foundation
import Testing
import UIKit
@testable import SleepTracker

/// `activate()` has to be safe to call twice in a row: a media-services reset mid-recording
/// calls it again without an intervening `deactivate()`, and it used to stack a second,
/// identical set of observers each time — doubling every interruption and background span
/// it reported for the rest of the night.
@MainActor
struct AudioSessionPolicyTests {
    @Test func activatingTwiceStillFiresEachSystemEventOnce() throws {
        let policy = AudioSessionPolicy()
        var backgroundedCount = 0
        policy.onSystemEvent = { event in
            if event == .backgrounded {
                backgroundedCount += 1
            }
        }

        try policy.activate()
        try policy.activate() // the reset path: activate again with no deactivate between

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        // Registered with `queue: .main`, so delivery is a main-queue block rather than an
        // inline call — give the run loop one short turn to actually deliver it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(backgroundedCount == 1, "activate() should not stack a second registration")

        policy.deactivate()
    }

    @Test func deactivateThenActivateRegistersExactlyOnce() throws {
        let policy = AudioSessionPolicy()
        var count = 0
        policy.onSystemEvent = { event in
            if event == .foregrounded {
                count += 1
            }
        }

        try policy.activate()
        policy.deactivate()
        try policy.activate()

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(count == 1)

        policy.deactivate()
    }
}
