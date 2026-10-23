import SwiftUI

@main
struct UsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Text(store.barLabel)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
