import SwiftUI

@main
struct SleepTrackerApp: App {
    init() {
        UITestFixtures.prepareIfRequested()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
