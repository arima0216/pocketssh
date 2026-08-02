import Foundation
import UIKit

/// アプリ内で完結する疑似シェル。
///
/// iOSのサンドボックスは fork/posix_spawn を禁止しているため、本物のシェルを
/// 子プロセスとして起動することはできない。ここではコマンド文字列を解釈して
/// FileManager や PhotoKit などのAPI呼び出しに変換している。
///
/// PhotoKit の待ち合わせに semaphore を使うため、`run` は必ず
/// バックグラウンドキューから呼ぶこと（メインスレッドだとデッドロックする）。
final class CommandShell {
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
        PocketSSH 0.4.0 — \(UIDevice.current.name)
        help でコマンド一覧、exit で切断。

        """
    }

    func prompt() -> String {
        "\(displayPath(cwd))$ "
    }

    func run(_ line: String) -> Result {
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
        case "catb64":
            guard args.count >= 3,
                  let offset = Int(args[1]),
                  let length = Int(args[2]) else {
                return Result(output: "使い方: catb64 <ファイル> <開始バイト> <バイト数>")
            }
            return Result(output: readFileBase64(args[0], offset: offset, length: length))
        case "rm":
            guard let name = args.first else { return Result(output: "rm: ファイル名が必要です") }
            return Result(output: removeFile(name))
        case "echo":
            return Result(output: args.joined(separator: " "))
        case "device":
            return Result(output: deviceInfo())
        case "date":
            return Result(output: ISO8601DateFormatter().string(from: Date()))
        case "photos":
            let limit = args.first.flatMap { Int($0) } ?? 20
            return Result(output: PhotoLibrary.list(limit: limit))
        case "photo":
            guard let index = args.first.flatMap({ Int($0) }) else {
                return Result(output: "使い方: photo <番号> [最大ピクセル]（photos で番号を確認）")
            }
            let maxPixel = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
            return Result(output: PhotoLibrary.base64JPEG(index: index,
                                                          maxPixel: CGFloat(maxPixel),
                                                          quality: 0.85))
        case "photoorig":
            guard let index = args.first.flatMap({ Int($0) }) else {
                return Result(output: "使い方: photoorig <番号>（photos で番号を確認）")
            }
            return Result(output: PhotoLibrary.base64Original(index: index))
        case "photodelall":
            guard args.first == "yes" else {
                return Result(output: "本当に全削除するなら photodelall yes と入力（iPhone側にも確認ダイアログが出ます）")
            }
            return Result(output: PhotoLibrary.deleteAllPhotos())
        case "videos":
            let limit = args.first.flatMap { Int($0) } ?? 20
            return Result(output: PhotoLibrary.listVideos(limit: limit))
        case "videothumb":
            guard let index = args.first.flatMap({ Int($0) }) else {
                return Result(output: "使い方: videothumb <番号> [最大ピクセル]（videos で番号を確認）")
            }
            let maxPixel = args.count > 1 ? (Double(args[1]) ?? 640) : 640
            return Result(output: PhotoLibrary.videoThumbnailJPEG(index: index,
                                                                  maxPixel: CGFloat(maxPixel)))
        case "videosave":
            guard let index = args.first.flatMap({ Int($0) }) else {
                return Result(output: "使い方: videosave <番号>（videos で番号を確認）")
            }
            return Result(output: PhotoLibrary.saveVideoToDocuments(index: index))
        case "videodelall":
            guard args.first == "yes" else {
                return Result(output: "本当に全削除するなら videodelall yes と入力（iPhone側にも確認ダイアログが出ます）")
            }
            return Result(output: PhotoLibrary.deleteAllVideos())
        case "exit", "quit":
            return Result(output: "", shouldClose: true)
        default:
            return Result(output: "\(command): コマンドが見つかりません（help で一覧）")
        }
    }

    // MARK: - コマンド実装

    private func helpText() -> String {
        """
        help                 このヘルプ
        pwd                  現在のディレクトリ
        ls [パス]            ファイル一覧
        cd <パス>            ディレクトリ移動
        cat <ファイル>       ファイルの中身（先頭64KBまで）
        catb64 <ファイル> <開始バイト> <バイト数>
                             ファイルの一部をBase64で出力（1回4MBまで／末尾は EOF）
        rm <ファイル>        ファイル削除（ディレクトリは不可）
        echo <文字列>        おうむ返し
        device               端末情報
        date                 現在時刻
        photos [件数]        写真を新しい順に一覧（既定20件）
        photo <番号> [px]    写真をJPEG/Base64で出力（既定 長辺1600px）
        photoorig <番号>     写真をオリジナル画質のままBase64で出力
        photodelall yes      写真を全削除（端末側の確認ダイアログが必要）
        videos [件数]        動画を新しい順に一覧（既定20件）
        videothumb <番号> [px]
                             動画のサムネイルをJPEG/Base64で出力（既定 長辺640px）
        videosave <番号>     動画を Documents に書き出し（そのあと catb64 で取り出す）
        videodelall yes      動画を全削除（端末側の確認ダイアログが必要）
        exit                 切断
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

    private func changeDirectory(_ path: String) -> String {
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

    /// ファイルの一部を切り出してBase64だけを返す（装飾なしの1行）。
    ///
    /// 動画のような大きいファイルをSSH経由で運ぶための分割転送用。PC側は offset を
    /// ずらしながら呼び、"EOF" が返ったら終わり。
    private func readFileBase64(_ name: String, offset: Int, length: Int) -> String {
        let target = resolve(name)
        guard target.path.hasPrefix(root.path),
              let handle = try? FileHandle(forReadingFrom: target) else {
            return "catb64: 開けません: \(name)"
        }
        defer { try? handle.close() }

        // 1回で流す量は4MBまでに抑える（メモリと行長の保険）
        let capped = min(max(length, 0), 4 * 1024 * 1024)
        guard capped > 0 else { return "EOF" }

        do {
            try handle.seek(toOffset: UInt64(max(offset, 0)))
        } catch {
            return "EOF"
        }
        let data = (try? handle.read(upToCount: capped)) ?? Data()
        if data.isEmpty { return "EOF" }
        return data.base64EncodedString()
    }

    private func removeFile(_ name: String) -> String {
        let target = resolve(name)
        guard target.path.hasPrefix(root.path) else {
            return "rm: サンドボックスの外は消せません"
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return "rm: そんなファイルはありません: \(name)"
        }
        guard !isDirectory.boolValue else {
            return "rm: ディレクトリは削除できません: \(name)"
        }
        do {
            try FileManager.default.removeItem(at: target)
            return "removed: \(target.lastPathComponent)"
        } catch {
            return "rm: 削除できませんでした: \(error.localizedDescription)"
        }
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
