import Foundation

enum RecognitionModel: String, CaseIterable, Identifiable {
    case parakeet
    case whisperTurbo
    case anthropicCloud

    var id: String { rawValue }
    var name: String {
        switch self {
        case .parakeet: return "Parakeet TDT 0.6B v3"
        case .whisperTurbo: return "Whisper large-v3-turbo Q8_0"
        case .anthropicCloud: return "Anthropic Cloud"
        }
    }
    var downloadDescription: String {
        switch self {
        case .parakeet: return "Около 570 МБ · CoreML"
        case .whisperTurbo: return "Около 890 МБ · GGUF · transcribe.cpp"
        case .anthropicCloud: return "Стриминг · нужен Claude Code"
        }
    }

    var isCloud: Bool { self == .anthropicCloud }
    var needsLocalModel: Bool { !isCloud }
}
