import Foundation

enum RecognitionModel: String, CaseIterable, Identifiable {
    case parakeet
    case whisperTurbo
    case anthropicCloud

    var id: String { rawValue }
    var name: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperTurbo: return "Whisper Large v3 Turbo"
        case .anthropicCloud: return "Anthropic Cloud"
        }
    }
    var downloadDescription: String {
        switch self {
        case .parakeet: return "Около 570 МБ"
        case .whisperTurbo: return "Около 630 МБ · CoreML"
        case .anthropicCloud: return "Стриминг · нужен Claude Code"
        }
    }

    var isCloud: Bool { self == .anthropicCloud }
    var needsLocalModel: Bool { !isCloud }
}
