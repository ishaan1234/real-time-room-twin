import SwiftUI

@main
struct RoomTwinApp: App {
    @StateObject private var account = Account()

    init() {
        Diagnostics.startWatchdog()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if account.session != nil {
                    ContentView()
                        .overlay(alignment: .topLeading) { AccountMenu() }
                        .environmentObject(account)
                } else {
                    LoginView(account: account)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
