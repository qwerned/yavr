import Foundation

enum RecognitionModel: String, CaseIterable, Identifiable {
    case parakeet
    case whisperTurbo

    var id: String { rawValue }
    var name: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperTurbo: return "Whisper Large v3 Turbo"
        }
    }
    var downloadDescription: String {
        switch self {
        case .parakeet: return "Около 570 МБ"
        case .whisperTurbo: return "Около 630 МБ · CoreML"
        }
    }
}
