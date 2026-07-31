import SwiftUI

@main
struct PocketSSHApp: App {
    @StateObject private var ssh = SSHServer(port: 2222)
    @StateObject private var plain = TCPServer(port: 2223)

    var body: some Scene {
        WindowGroup {
            ContentView(ssh: ssh, plain: plain)
        }
    }
}
