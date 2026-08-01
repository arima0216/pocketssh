import Foundation
import Photos
import UIKit

/// 写真ライブラリへのアクセス。
///
/// PhotoKit のAPIは非同期なので、呼び出し側（バックグラウンドキュー上で動く疑似シェル）
/// からは semaphore で完了を待って同期的に扱う。メインスレッドから呼ぶとデッドロックする。
enum PhotoLibrary {

    // MARK: - 権限

    private static func authorize(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { updated in
                completion(updated == .authorized || updated == .limited)
            }
        default:
            completion(false)
        }
    }

    private static func waitForAuthorization() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        authorize { result in
            granted = result
            semaphore.signal()
        }
        // 初回は端末側に許可ダイアログが出るので長めに待つ
        _ = semaphore.wait(timeout: .now() + 60)
        return granted
    }

    private static func fetch(limit: Int) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit > 0 { options.fetchLimit = limit }
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    // MARK: - コマンド実装

    /// 新しい順に一覧を返す。
    static func list(limit: Int) -> String {
        guard waitForAuthorization() else {
            return "写真へのアクセスが許可されていません（設定→プライバシーとセキュリティ→写真）"
        }
        let assets = fetch(limit: limit)
        guard assets.count > 0 else { return "（写真なし）" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        assets.enumerateObjects { asset, index, _ in
            let date = asset.creationDate.map { formatter.string(from: $0) } ?? "日時不明"
            let size = "\(asset.pixelWidth)x\(asset.pixelHeight)"
            lines.append(String(format: "%3d  %@  %@", index, date, size))
        }
        return lines.joined(separator: "\n")
    }

    /// 指定インデックスの写真をJPEGにしてBase64で返す（76文字で折り返し）。
    static func base64JPEG(index: Int, maxPixel: CGFloat, quality: CGFloat) -> String {
        guard waitForAuthorization() else {
            return "写真へのアクセスが許可されていません（設定→プライバシーとセキュリティ→写真）"
        }
        let assets = fetch(limit: 0)
        guard index >= 0, index < assets.count else {
            return "photo: 範囲外のインデックス（0〜\(max(assets.count - 1, 0))）"
        }
        let asset = assets.object(at: index)

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud上の写真も取りに行く
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false

        let scale = min(1.0, maxPixel / CGFloat(max(asset.pixelWidth, asset.pixelHeight)))
        let target = CGSize(width: CGFloat(asset.pixelWidth) * scale,
                            height: CGFloat(asset.pixelHeight) * scale)

        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: target,
                                              contentMode: .aspectFit,
                                              options: options) { result, info in
            // degraded（低解像度の先出し）は無視して本命だけ受け取る
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if degraded { return }
            image = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 60)

        guard let data = image?.jpegData(compressionQuality: quality) else {
            return "photo: 画像を取得できませんでした"
        }

        let encoded = data.base64EncodedString()
        let date = asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        var body = "-----BEGIN PHOTO-----\n"
        body += "index: \(index)\ndate: \(date)\nbytes: \(data.count)\n\n"
        body += wrap(encoded, width: 76)
        body += "\n-----END PHOTO-----"
        return body
    }

    private static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[start..<end]))
            start = end
        }
        return lines.joined(separator: "\n")
    }
}
