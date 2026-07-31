import Foundation
import UIKit

/// アプリ内で完結する疑似シェル。
///
/// iOSのサンドボックスは fork/posix_spawn を禁止しているため、本物のシェルを
/// 子プロセスとして起動することはできない。ここではコマンド文字列を解釈して
/// FileManager などのAPI呼び出しに変換している。
/// 触れる範囲はアプリ自身のサンドボックス（Documents 以下）に限られる。
struct CommandShell {
    struct Result {
        var output: String
        var shouldClose: Bool = false
    }

    private let root: URL
    private var cwd: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents
        cwd = documents
    }

    func banner() -> String {
        """
        PocketSSH 0.1.0 — \(UIDevice.current.name)
        アプリのサンドボックス内だけを見られる疑似シェルです。
        help でコマンド一覧、exit で切断。

        """
    }

    func prompt() -> String {
        "\(displayPath(cwd))$ "
    }

    mutating func run(_ line: String) -> Result {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return Result(output: "") }
        let args = Array(parts.dropFirst())

        switch command {
        case "help":
            return Result(output: helpText())
        case "pwd":
            return Result(output: displayPath(cwd))
        case "ls":
            return Result(output: list(args.first))
        case "cd":
            return Result(output: changeDirectory(args.first ?? "/"))
        case "cat":
            guard let name = args.first else { return Result(output: "cat: ファイル名が必要です") }
            return Result(output: readFile(name))
        case "echo":
            return Result(output: args.joined(separator: " "))
        case "device":
            return Result(output: deviceInfo())
        case "date":
            return Result(output: ISO8601DateFormatter().string(from: Date()))
        case "exit", "quit":
            return Result(output: "", shouldClose: true)
        default:
            return Result(output: "\(command): コマンドが見つかりません（help で一覧）")
        }
    }

    // MARK: - コマンド実装

    private func helpText() -> String {
        """
        help              このヘルプ
        pwd               現在のディレクトリ
        ls [パス]         ファイル一覧
        cd <パス>         ディレクトリ移動
        cat <ファイル>    ファイルの中身（先頭64KBまで）
        echo <文字列>     おうむ返し
        device            端末情報
        date              現在時刻
        exit              切断
        """
    }

    private func list(_ path: String?) -> String {
        let target = path.map { resolve($0) } ?? cwd
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else {
            return "ls: 開けません: \(displayPath(target))"
        }
        if entries.isEmpty { return "（空）" }
        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    return "\(url.lastPathComponent)/"
                }
                let size = values?.fileSize ?? 0
                return "\(url.lastPathComponent)  \(size) bytes"
            }
            .joined(separator: "\n")
    }

    private mutating func changeDirectory(_ path: String) -> String {
        let target = resolve(path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return "cd: そんなディレクトリはありません: \(path)"
        }
        guard target.path.hasPrefix(root.path) else {
            return "cd: サンドボックスの外には出られません"
        }
        cwd = target
        return ""
    }

    private func readFile(_ name: String) -> String {
        let target = resolve(name)
        guard target.path.hasPrefix(root.path),
              let handle = try? FileHandle(forReadingFrom: target) else {
            return "cat: 開けません: \(name)"
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "（テキストではありません: \(data.count) bytes）"
    }

    private func deviceInfo() -> String {
        let device = UIDevice.current
        return """
        name:    \(device.name)
        model:   \(device.model)
        system:  \(device.systemName) \(device.systemVersion)
        sandbox: \(root.path)
        """
    }

    // MARK: - パス解決

    private func resolve(_ path: String) -> URL {
        if path == "/" { return root }
        if path.hasPrefix("/") {
            return root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        }
        return cwd.appendingPathComponent(path).standardizedFileURL
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path.replacingOccurrences(of: root.path, with: "")
        return path.isEmpty ? "/" : path
    }
}
