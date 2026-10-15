import CryptoKit
import Foundation
import ZimuCore

enum UpdateDownloadError: LocalizedError {
    case blockedRedirect(String)
    case http(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .blockedRedirect(let host):
            return "下载地址被重定向到了不可信的位置（\(host)），已停止下载"
        case .http(let status):
            return "下载更新失败（HTTP \(status)）"
        case .sizeMismatch(let expected, let actual):
            return "下载的文件大小不对（应为 \(expected) 字节，实际 \(actual) 字节）"
        case .checksumMismatch:
            return "下载的文件校验失败（SHA-256 不一致），可能已损坏或被篡改，已删除"
        case .cancelled:
            return "已取消下载"
        }
    }
}

/// 下载更新包（决策 D21）：重定向白名单、大小上限、SHA-256 校验
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let asset: UpdateAsset
    private let repository: String
    private let destinationDirectory: URL
    private let progress: @MainActor (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var failure: Error?
    private var lastReported: Double = -1

    init(asset: UpdateAsset, repository: String, destinationDirectory: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.asset = asset
        self.repository = repository
        self.destinationDirectory = destinationDirectory
        self.progress = progress
    }

    /// 下载并校验，返回校验通过的文件
    func start() async throws -> URL {
        guard UpdatePolicy.isAllowedDownloadURL(asset.url, repository: repository) else {
            throw UpdateDownloadError.blockedRedirect(asset.url.host ?? asset.url.absoluteString)
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 30 * 60
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: asset.url)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                let task = session.downloadTask(with: request)
                lock.withLock {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }

        do {
            try await Self.verify(file: downloaded, size: asset.size, sha256: asset.sha256)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        return downloaded
    }

    func cancel() {
        lock.withLock {
            if failure == nil { failure = UpdateDownloadError.cancelled }
            return task
        }?.cancel()
    }

    /// 在后台线程分块计算 SHA-256
    static func verify(file: URL, size: Int64, sha256 expected: String) async throws {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == size else {
                throw UpdateDownloadError.sizeMismatch(expected: size, actual: actualSize)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == expected.lowercased() else { throw UpdateDownloadError.checksumMismatch }
        }.value
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, UpdatePolicy.isAllowedDownloadURL(url, repository: repository) else {
            lock.withLock { failure = UpdateDownloadError.blockedRedirect(request.url?.host ?? "?") }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > asset.size {
            lock.withLock { failure = UpdateDownloadError.sizeMismatch(expected: asset.size, actual: totalBytesWritten) }
            downloadTask.cancel()
            return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(max(1, asset.size)))
        let shouldReport = lock.withLock { () -> Bool in
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return false }
            lastReported = fraction
            return true
        }
        if shouldReport {
            let progress = self.progress
            Task { @MainActor in progress(fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 必须在这个回调返回前把临时文件移走
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { failure = failure ?? UpdateDownloadError.http(http.statusCode) }
            return
        }
        let destination = destinationDirectory.appendingPathComponent(asset.name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            lock.withLock { failure = failure ?? error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let stored = lock.withLock { failure }
        if let stored {
            finish(.failure(stored))
        } else if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? UpdateDownloadError.cancelled : error))
        } else {
            // 成功时 didFinishDownloadingTo 已经完成了 continuation；这里兜底
            finish(.failure(UpdateDownloadError.http((task.response as? HTTPURLResponse)?.statusCode ?? 0)))
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(with: result)
    }
}
