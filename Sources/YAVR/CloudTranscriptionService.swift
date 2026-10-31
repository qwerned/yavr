import Foundation
import os.log

private let log = Logger(subsystem: "com.yavr", category: "CloudSTT")

/// Стриминговое распознавание через Anthropic STT (WebSocket).
/// Токен достаётся из Keychain (Claude Code-credentials).
actor CloudTranscriptionService {
    static let shared = CloudTranscriptionService()

    private static let wsBase = "wss://api.anthropic.com/api/ws/speech_to_text/voice_stream"
    private static let origin = "https://claude.ai"
    private static let keychainService = "Claude Code-credentials"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) claude-desktop/4.4212.0 Chrome/152.0.7977.167 Electron/44.9.3 Safari/537.36"

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var keepAliveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    /// Завершённые фразы (TranscriptText) этой сессии, склеенные.
    private var committedText = ""
    /// Текущая незавершённая фраза (последний TranscriptInterim).
    private var currentPartial = ""
    /// CloseStream отправлен: закрытие сокета дальше — штатное, не ошибка.
    private var closing = false
    /// Причина, по которой сессия оборвалась до финала.
    private var failure: String?
    private var onInterim: (@Sendable (String) -> Void)?
    private var refreshTask: Task<Void, Never>?

    /// Весь текст сессии: завершённые фразы + текущая незавершённая.
    private var combinedText: String {
        [committedText, currentPartial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Токен

    private struct Credentials {
        let token: String
        let expiresAt: Date?
    }

    /// Через /usr/bin/security, а не SecItemCopyMatching: claude перезаписывает
    /// запись этой утилитой (`add-generic-password -U`), и macOS сбрасывает
    /// доступ всем, кроме неё, — YAVR спрашивал бы пароль связки после каждого
    /// обновления токена.
    nonisolated private static func readCredentials() -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: token, expiresAt: expiresAt)
    }

    nonisolated static var isAvailable: Bool { readCredentials() != nil }

    /// Токен живёт около 8 часов, а обновляет его только сама утилита claude
    /// при запросе. Короткий запрос к Haiku незадолго до истечения держит
    /// токен свежим; ключ обновления остаётся у claude, и они не расходятся.
    /// Запас меньше 5 минут: раньше этого claude токен не обновляет
    /// (порог в его коде — `now + 300000 >= expiresAt`).
    func refreshTokenIfNeeded(margin: TimeInterval = 4 * 60) async {
        if let refreshTask { return await refreshTask.value }
        guard let expiresAt = Self.readCredentials()?.expiresAt,
            expiresAt.timeIntervalSinceNow < margin
        else { return }
        let task = Task.detached { Self.pingClaude() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    nonisolated private static func pingClaude() {
        let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { NSString(string: $0).expandingTildeInPath }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else {
            log.error("token refresh: claude not found")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-p", "--no-session-persistence", "--model", "haiku", "Ответь одним словом: ок",
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        log.notice("token refresh: claude exited \(process.terminationStatus)")
    }

    // MARK: - Сессия

    /// Подключается и отправляет звук из `audio` строго по порядку. Куски,
    /// записанные до подключения, ждут в потоке и не теряются. Черновики
    /// текста (вся сессия целиком) приходят в `onInterim`. Истёкший токен
    /// (Mac спал) сначала обновляется — звук тем временем копится в потоке.
    func startSession(
        language: String, audio: AsyncStream<Data>,
        onInterim: @escaping @Sendable (String) -> Void
    ) async throws {
        cleanup()
        await refreshTokenIfNeeded(margin: 60)
        guard let token = Self.readCredentials()?.token else { throw CloudSTTError.noToken }

        var components = URLComponents(string: Self.wsBase)!
        components.queryItems = [
            "encoding": "linear16", "sample_rate": "16000", "channels": "1",
            "endpointing_ms": "300", "utterance_end_ms": "1000", "language": language,
            "use_conversation_engine": "true", "forward_interims": "typed",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocket = task
        self.onInterim = onInterim
        task.resume()

        sendText(#"{"type":"KeepAlive"}"#)
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                sendText(#"{"type":"KeepAlive"}"#)
            }
        }
        senderTask = Task {
            for await chunk in audio {
                webSocket?.send(.data(chunk)) { error in
                    if let error { log.error("audio send: \(error.localizedDescription)") }
                }
            }
        }
        listen()
    }

    /// Ждёт, пока уйдёт весь звук (вызывающий уже закрыл поток), закрывает
    /// стрим и возвращает финальный текст.
    func finishSession() async throws -> String {
        await senderTask?.value
        closing = true
        sendText(#"{"type":"CloseStream"}"#)

        // Сервер присылает финал и сам закрывает сокет; ждём до 8 секунд.
        let deadline = Date().addingTimeInterval(8)
        while webSocket != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        let result = combinedText
        let failure = failure
        cleanup()
        if result.isEmpty, let failure { throw CloudSTTError.connectionFailed(failure) }
        return result
    }

    func cancel() {
        cleanup()
    }

    private func sendText(_ text: String) {
        webSocket?.send(.string(text)) { _ in }
    }

    private func cleanup() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        senderTask?.cancel()
        senderTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        committedText = ""
        currentPartial = ""
        closing = false
        failure = nil
        onInterim = nil
    }

    // MARK: - Приём

    private func listen() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handle(result) }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(.string(let text)):
            if let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                handle(json)
            }
            listen()
        case .success:
            listen()
        case .failure(let error):
            if !closing && failure == nil { failure = error.localizedDescription }
            log.notice("WebSocket closed: \(error.localizedDescription)")
            webSocket = nil
        }
    }

    private func handle(_ json: [String: Any]) {
        let transcript = (json["text"] ?? json["data"] ?? json["transcript"]) as? String
        switch json["type"] as? String {
        case "TranscriptInterim":
            guard let transcript else { return }
            currentPartial = transcript
            onInterim?(combinedText)
        case "TranscriptText":
            // Фраза завершена сервером — переносим её в накопленный текст.
            guard let transcript else { return }
            committedText = [committedText, transcript].filter { !$0.isEmpty }.joined(separator: " ")
            currentPartial = ""
            onInterim?(combinedText)
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String
            failure = message ?? "ошибка сервера"
            log.error("Server error: \(self.failure ?? "")")
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        default:
            break  // TranscriptEndpoint и прочее: текст уже накоплен
        }
    }
}

enum CloudSTTError: LocalizedError {
    case noToken
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Нет токена Claude Code — запустите claude auth login"
        case .connectionFailed(let reason): return "Облачное распознавание: \(reason)"
        }
    }
}
