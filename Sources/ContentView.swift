import SwiftUI

struct ContentView: View {
    @ObservedObject var server: TCPServer

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusCard
                connectHint
                logView
            }
            .padding()
            .navigationTitle("PocketSSH")
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(server.isRunning ? .green : .secondary)
                    .frame(width: 12, height: 12)
                Text(server.isRunning ? "待ち受け中" : "停止中")
                    .font(.headline)
                Spacer()
                Text("接続 \(server.clientCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                server.isRunning ? server.stop() : server.start()
            } label: {
                Text(server.isRunning ? "停止" : "起動")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(server.isRunning ? .red : .accentColor)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PCから接続")
                .font(.subheadline.bold())
            Text(LocalIPAddress.current().map { "nc \($0) \(server.port)" } ?? "Wi-Fi未接続")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("アプリを前面に出している間だけ接続できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(server.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
            }
            .onChange(of: server.log.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Wi-Fi インターフェイス(en0)のIPv4アドレスを取得する。
enum LocalIPAddress {
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var result: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            if status == 0 { result = String(cString: buffer) }
        }
        return result
    }
}
