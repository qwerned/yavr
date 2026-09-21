import Foundation

/// One recording or transcription at a time. IDs reject late completions.
public struct DictationSession {
    public enum Phase: Equatable { case idle, recording, transcribing }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let newID = UUID()
        id = newID
        phase = .recording
        return newID
    }
    public mutating func transcribe() -> UUID? {
        guard phase == .recording else { return nil }
        phase = .transcribing
        return id
    }
    @discardableResult public mutating func finish(_ completedID: UUID) -> Bool {
        guard id == completedID else { return false }
        cancel()
        return true
    }
    public mutating func cancel() { phase = .idle; id = nil }
}
