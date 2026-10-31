import AVFoundation
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
    private var keepAliveTimer: Timer?
    /// Завершённые фразы (TranscriptText) этой сессии, склеенные.
    private var committedText = ""
    /// Текущая незавершённая фраза (последний TranscriptInterim).
    private var currentPartial = ""

    /// Весь текст сессии: завершённые фразы + текущая незавершённая.
    private var combinedText: String {
        var s = committedText
        if !currentPartial.isEmpty {
            if !s.isEmpty && !s.hasSuffix(" ") { s += " " }
            s += currentPartial
        }
        return s
    }

    /// Обратный вызов при каждом interim-обновлении текста (main thread).
    private var _onInterimUpdate: (@Sendable (String) -> Void)?

    func setOnInterimUpdate(_ handler: (@Sendable (String) -> Void)?) {
        _onInterimUpdate = handler
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

extension CloudTranscriptionService {

    // MARK: - Streaming session

    /// Начинает стриминговую сессию: подключается к WebSocket.
    func startSession(language: String) async throws {
        guard let token = Self.readAccessToken() else {
            throw CloudSTTError.noToken
        }

        committedText = ""
        currentPartial = ""

        var components = URLComponents(string: Self.wsBase)!
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing_ms", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "use_conversation_engine", value: "true"),
            URLQueryItem(name: "forward_interims", value: "typed"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.urlSession = session
        self.webSocket = task
        task.resume()

        sendKeepAlive()
        startKeepAliveTimer()
        listenForMessages()
    }

    /// Отправляет кусок PCM-аудио (Int16 LE, 16 kHz, mono).
    func sendAudioChunk(_ chunk: Data) {
        guard let ws = webSocket else { return }
        ws.send(.data(chunk)) { error in
            if let error {
                log.error("sendAudioChunk: send error: \(error.localizedDescription)")
            }
        }
    }

    /// Закрывает стрим и возвращает финальный текст.
    func finishSession() async throws -> String {
        let closeMessage = try JSONSerialization.data(
            withJSONObject: ["type": "CloseStream"])
        webSocket?.send(.string(String(data: closeMessage, encoding: .utf8)!)) { error in
            if let error {
                log.error("finishSession: CloseStream send error: \(error.localizedDescription)")
            }
        }

        // Ждём финальный ответ (до 8 секунд)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if webSocket == nil { break }
        }

        let result = combinedText
        cleanup()
        return result
    }

    func cancel() {
        cleanup()
    }

    private func sendKeepAlive() {
        webSocket?.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
    }

    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.sendKeepAlive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func cleanup() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        committedText = ""
        currentPartial = ""
        _onInterimUpdate = nil
    }

    /// Отдаёт весь накопленный текст сессии наблюдателю (main thread).
    private func emitCombined() {
        let captured = combinedText
        let callback = _onInterimUpdate
        Task { @MainActor in callback?(captured) }
    }

    // MARK: - Receiving

    private func listenForMessages() {
        guard let ws = webSocket else {
            log.notice("listenForMessages: webSocket is nil")
            return
        }
        ws.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleMessage(result) }
        }
    }

    private func handleMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    let type = json["type"] as? String ?? ""
                    let transcript = (json["text"] as? String)
                        ?? (json["data"] as? String)
                        ?? (json["transcript"] as? String)
                    if type == "TranscriptInterim" {
                        if let transcript {
                            currentPartial = transcript
                            emitCombined()
                        }
                    } else if type == "TranscriptText" {
                        // Фраза завершена сервером — переносим её в накопленный текст.
                        if let transcript {
                            if !committedText.isEmpty && !committedText.hasSuffix(" ") {
                                committedText += " "
                            }
                            committedText += transcript
                            currentPartial = ""
                            emitCombined()
                        }
                    } else if type == "TranscriptEndpoint" {
                        // Сервер закрыл фразу; текст уже накоплен в committedText.
                    } else if type == "error" {
                        if let error = json["error"] as? [String: Any],
                            let msg = error["message"] as? String
                        {
                            log.error("Server error: \(msg)")
                            committedText = ""
                            currentPartial = ""
                            let callback = _onInterimUpdate
                            Task { @MainActor in callback?("[Ошибка: \(msg)]") }
                        }
                        cleanup()
                        return
                    }
                }
            case .data(let d):
                log.notice("Binary message: \(d.count) bytes")
            @unknown default:
                break
            }
            listenForMessages()
        case .failure(let error):
            log.notice("WebSocket closed: \(error.localizedDescription)")
            webSocket = nil
        }
    }
}
