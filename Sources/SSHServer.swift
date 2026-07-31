import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import UIKit

/// swift-nio-ssh を使った本物のSSHサーバー。
///
/// 認証はパスワードのみ。シェルは CommandShell（アプリ内疑似シェル）に繋ぐ。
/// iOSでは子プロセスを起動できないため、PTYは要求されても拒否する
/// （クライアント側がライン入力＋ローカルエコーで動作するのでこの方が扱いやすい）。
final class SSHServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []

    let port: UInt16
    let password: String

    private var group: EventLoopGroup?
    private var channel: Channel?

    init(port: UInt16) {
        self.port = port
        self.password = SSHServer.loadOrCreatePassword()
    }

    // MARK: - 制御

    func start() {
        guard group == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let hostKey = SSHServer.loadOrCreateHostKey()
        let auth = PasswordDelegate(password: password) { [weak self] line in
            self?.append(line)
        }
        let logger: (String) -> Void = { [weak self] line in self?.append(line) }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            guard case .session = channelType else {
                                return child.eventLoop.makeFailedFuture(SSHError.unsupportedChannel)
                            }
                            return child.pipeline.addHandler(SessionHandler(log: logger))
                        }
                    ),
                    ConnectionLogger(log: logger),
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        bootstrap.bind(host: "0.0.0.0", port: Int(port)).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.channel = channel
                self.setRunning(true)
                self.append("SSH待ち受け開始 (ポート \(self.port))")
            case .failure(let error):
                self.append("SSH起動失敗: \(error)")
                self.stop()
            }
        }
    }

    func stop() {
        channel?.close(promise: nil)
        channel = nil
        try? group?.syncShutdownGracefully()
        group = nil
        setRunning(false)
        append("SSH停止")
    }

    // MARK: - 永続化

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// ホスト鍵はファイルに保存する。毎回変わるとクライアントが警告を出すため。
    private static func loadOrCreateHostKey() -> NIOSSHPrivateKey {
        let url = supportDir.appendingPathComponent("host_ed25519.key")
        if let data = try? Data(contentsOf: url),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return NIOSSHPrivateKey(ed25519Key: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try? key.rawRepresentation.write(to: url, options: .completeFileProtection)
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    /// 初回起動時にランダムなパスワードを作り、以後は使い回す。
    private static func loadOrCreatePassword() -> String {
        let key = "ssh_password"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let generated = String((0..<10).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    // MARK: - 状態

    private func setRunning(_ value: Bool) {
        DispatchQueue.main.async { self.isRunning = value }
    }

    private func append(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let stamped = "\(f.string(from: Date())) \(line)"
        DispatchQueue.main.async {
            self.log.append(stamped)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }
}

enum SSHError: Error {
    case unsupportedChannel
}

// MARK: - 認証

private final class PasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    private let password: String
    private let log: (String) -> Void

    init(password: String, log: @escaping (String) -> Void) {
        self.password = password
        self.log = log
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard case .password(let offered) = request.request else {
            log("認証失敗: パスワード以外の方式 (\(request.username))")
            responsePromise.succeed(.failure)
            return
        }
        if offered.password == password {
            log("認証成功: \(request.username)")
            responsePromise.succeed(.success)
        } else {
            log("認証失敗: パスワード不一致 (\(request.username))")
            responsePromise.succeed(.failure)
        }
    }
}

// MARK: - 接続ログ

private final class ConnectionLogger: ChannelInboundHandler {
    typealias InboundIn = Any

    private let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }

    func channelActive(context: ChannelHandlerContext) {
        log("接続: \(context.remoteAddress?.description ?? "?")")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        log("切断: \(context.remoteAddress?.description ?? "?")")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        log("エラー: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - セッション（シェル）

private final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private var shell = CommandShell()
    private var buffer = ""
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { error in
                context.fireErrorCaught(error)
            }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is SSHChannelRequestEvent.PseudoTerminalRequest:
            // iOSでは本物のTTYを用意できない。拒否するとクライアントは
            // ライン入力モードで動作するため、こちらの方が具合が良い。
            context.fireErrorCaught(SSHError.unsupportedChannel)
        case is SSHChannelRequestEvent.ShellRequest:
            write(context, shell.banner())
            write(context, shell.prompt())
        case let exec as SSHChannelRequestEvent.ExecRequest:
            let result = shell.run(exec.command)
            if !result.output.isEmpty {
                write(context, result.output.hasSuffix("\n") ? result.output : result.output + "\n")
            }
            finish(context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data, channelData.type == .channel else {
            return
        }
        buffer += String(buffer: bytes)
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[buffer.startIndex..<index])
            buffer.removeSubrange(buffer.startIndex...index)
            handle(context, line: line)
        }
    }

    private func handle(_ context: ChannelHandlerContext, line: String) {
        let result = shell.run(line.trimmingCharacters(in: .whitespaces))
        if !result.output.isEmpty {
            write(context, result.output.hasSuffix("\n") ? result.output : result.output + "\n")
        }
        if result.shouldClose {
            write(context, "bye\n")
            finish(context)
            return
        }
        write(context, shell.prompt())
    }

    private func write(_ context: ChannelHandlerContext, _ text: String) {
        // SSHは改行に CRLF を期待する
        let normalized = text.replacingOccurrences(of: "\n", with: "\r\n")
        let buffer = context.channel.allocator.buffer(string: normalized)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
                              promise: nil)
    }

    private func finish(_ context: ChannelHandlerContext) {
        _ = context.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
            .flatMap { context.channel.close() }
    }
}
