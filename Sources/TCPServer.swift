import Foundation
import Network
import UIKit

/// ローカルネットワークで待ち受けるTCPサーバー。
///
/// iOSはアプリがバックグラウンドに入るとリッスン中のソケットを回収するため、
/// このサーバーは「アプリを前面に出している間だけ」動く前提で作ってある。
final class TCPServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []
    @Published private(set) var clientCount = 0

    let port: UInt16

    private let queue = DispatchQueue(label: "dev.momo.pocketssh.server")
    private var listener: NWListener?
    private var sessions: [UUID: ClientSession] = [:]

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - 制御

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            append("不正なポート番号: \(port)")
            return
        }

        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.append("ポート \(self.port) で待ち受け開始")
                    self.setRunning(true)
                case .failed(let error):
                    self.append("待ち受け失敗: \(error.localizedDescription)")
                    self.stop()
                case .cancelled:
                    self.setRunning(false)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            // 画面が消えるとサスペンドされるので、稼働中は自動ロックを止める
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
        } catch {
            append("起動エラー: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.sessions.values { session.close() }
            self.sessions.removeAll()
            self.publishClientCount(0)
        }
        setRunning(false)
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        append("停止しました")
    }

    func clearLog() {
        DispatchQueue.main.async { self.log.removeAll() }
    }

    // MARK: - 接続

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = ClientSession(id: id, connection: connection, queue: queue)
        session.onLog = { [weak self] line in self?.append(line) }
        session.onClose = { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: id)
            self.publishClientCount(self.sessions.count)
        }
        sessions[id] = session
        publishClientCount(sessions.count)
        session.start()
    }

    // MARK: - 状態の反映

    private func setRunning(_ value: Bool) {
        DispatchQueue.main.async { self.isRunning = value }
    }

    private func publishClientCount(_ value: Int) {
        DispatchQueue.main.async { self.clientCount = value }
    }

    private func append(_ line: String) {
        let stamped = "\(Self.timestamp()) \(line)"
        DispatchQueue.main.async {
            self.log.append(stamped)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - クライアント1接続分

private final class ClientSession {
    let id: UUID
    var onLog: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let shell = CommandShell()
    /// シェルは PhotoKit の完了待ちで詰まるので専用キューで回す。
    private let shellQueue = DispatchQueue(label: "dev.momo.pocketssh.tcpshell")
    private var buffer = Data()

    init(id: UUID, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onLog?("接続: \(self.peerDescription())")
                self.send(self.shell.banner())
                self.send(self.shell.prompt())
                self.receive()
            case .failed, .cancelled:
                self.onLog?("切断: \(self.peerDescription())")
                self.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// 受信バッファを改行で切り出して1行ずつシェルに渡す。
    private func drainLines() {
        while let index = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            handle(line)
        }
    }

    private func handle(_ line: String) {
        shellQueue.async { [weak self] in
            guard let self else { return }
            let result = self.shell.run(line)
            if !result.output.isEmpty {
                self.send(result.output.hasSuffix("\n") ? result.output : result.output + "\n")
            }
            if result.shouldClose {
                self.send("bye\n")
                self.connection.cancel()
                return
            }
            self.send(self.shell.prompt())
        }
    }

    private func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .idempotent)
    }

    private func peerDescription() -> String {
        if case let .hostPort(host, port) = connection.endpoint {
            return "\(host):\(port)"
        }
        return "\(connection.endpoint)"
    }
}
