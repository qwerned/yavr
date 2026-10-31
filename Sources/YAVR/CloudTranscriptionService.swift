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

    /// Весь текст сессии: завершённые фразы + текущая незавершённая.
    private var combinedText: String {
        [committedText, currentPartial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Keychain

    nonisolated static func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    nonisolated static var isAvailable: Bool { readAccessToken() != nil }

    // MARK: - Сессия

    /// Подключается и отправляет звук из `audio` строго по порядку. Куски,
    /// записанные до подключения, ждут в потоке и не теряются. Черновики
    /// текста (вся сессия целиком) приходят в `onInterim`.
    func startSession(
        language: String, audio: AsyncStream<Data>,
        onInterim: @escaping @Sendable (String) -> Void
    ) throws {
        cleanup()
        guard let token = Self.readAccessToken() else { throw CloudSTTError.noToken }

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
