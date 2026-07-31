import SwiftUI

@main
struct PocketSSHApp: App {
    @StateObject private var server = TCPServer(port: 2222)

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
        }
    }
}
