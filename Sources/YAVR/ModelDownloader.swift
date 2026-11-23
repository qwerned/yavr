import CryptoKit
import Foundation

/// Файл модели с HuggingFace, закреплённый на коммите, размере и SHA-256.
struct PinnedModelFile: Sendable {
    let repo: String
    let revision: String
    let name: String
    let size: Int64
    let sha256: String

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(name)?download=true")!
    }
}

/// Скачивание с докачкой после обрыва: недокачанное лежит в `<имя>.part`,
/// следующий запуск продолжает с того же байта (HTTP Range). Готовый файл
/// проверяется по SHA-256 и только потом получает своё имя; рядом ставится
/// метка `.verified`, чтобы при каждом запуске не считать хеш заново.
enum ModelDownloader {
    enum DownloadError: LocalizedError {
        case http(Int)
        case checksum(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return "Сервер моделей ответил \(code)"
            case .checksum(let name): return "Файл \(name) скачался повреждённым — попробуйте ещё раз"
            }
        }
    }

    static func isInstalled(_ file: PinnedModelFile, in directory: URL) -> Bool {
        let path = directory.appendingPathComponent(file.name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? -1
        return size == file.size
            && FileManager.default.fileExists(atPath: marker(file, in: directory).path)
    }

    /// Ставит уже лежащий на диске файл (например, скачанный другим
    /// приложением), если он совпадает по размеру и хешу. false — не подошёл.
    static func adopt(_ source: URL, as file: PinnedModelFile, in directory: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? -1
        guard size == file.size, (try? sha256(of: source)) == file.sha256 else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            try Data(file.sha256.utf8).write(to: marker(file, in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func download(
        _ file: PinnedModelFile, to directory: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if isInstalled(file, in: directory) { progress(file.size); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(file.name)
        let part = directory.appendingPathComponent(file.name + ".part")

        try await ResumableTransfer(url: file.url, part: part, expected: file.size, progress: progress).run()

        guard try sha256(of: part) == file.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw DownloadError.checksum(file.name)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        try Data(file.sha256.utf8).write(to: marker(file, in: directory), options: .atomic)
    }

    private static func marker(_ file: PinnedModelFile, in directory: URL) -> URL {
        directory.appendingPathComponent(file.name + ".verified")
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Один HTTP-запрос с Range, пишущий тело в конец `.part`.
private final class ResumableTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let expected: Int64
    private let progress: @Sendable (Int64) -> Void
    // Ниже — только из очереди делегата (она последовательная).
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL, part: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.part = part
        self.expected = expected
        self.progress = progress
    }

    func run() async throws {
        let fm = FileManager.default
        written = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if written > expected {
            try? fm.removeItem(at: part)
            written = 0
        }
        if written == expected { return }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        handle = try FileHandle(forWritingTo: part)
        try handle?.seekToEnd()

        var request = URLRequest(url: url)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    guard !self.cancelled else { c.resume(throwing: CancellationError()); return }
                    self.continuation = c
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            queue.addOperation {
                self.cancelled = true
                session.invalidateAndCancel()
            }
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            break
        case 200:
            // Сервер не поддержал Range — начинаем файл сначала.
            if written > 0 {
                try? handle?.truncate(atOffset: 0)
                written = 0
            }
        default:
            failure = ModelDownloader.DownloadError.http(status)
            completionHandler(.cancel)
            return
        }
        progress(written)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result = failure ?? error
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
}
