import Foundation

/// Печатает черновик распознавания прямо в активное поле по ходу диктовки.
/// Меняется только расходящийся хвост: лишнее стирается Backspace, новое
/// вставляется через буфер. Cmd+Z не используется: редакторы склеивают правки
/// в один шаг отмены, и отмена снимала бы больше, чем последнюю вставку.
/// Шаги идут по одному с паузой, чтобы приложение успело прочитать буфер до
/// следующей записи в него; черновики, пришедшие за паузу, сливаются в один шаг.
@MainActor
final class LiveTyper {
    private static let settle: Duration = .milliseconds(80)

    /// Что сейчас стоит в поле.
    private var typed = ""
    private var target = ""
    private var busy = false
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func update(_ text: String) {
        target = text
        step()
    }

    /// Доводит поле до `text` и ждёт, пока шаги закончатся. false — печатать
    /// стало нельзя (защищённый ввод, отозван доступ), поле не совпадает с `text`.
    func finish(with text: String) async -> Bool {
        target = text
        step()
        while busy { await withCheckedContinuation { waiters.append($0) } }
        return !blocked && typed == target
    }

    private func step() {
        guard !busy, !blocked, typed != target else { return }
        guard Paster.canType else { blocked = true; return }
        busy = true

        let common = zip(typed, target).prefix { $0 == $1 }.count
        Paster.deleteBackward(typed.count - common)
        let addition = String(target.dropFirst(common))
        if !addition.isEmpty { Paster.paste(addition) }
        typed = target

        Task {
            try? await Task.sleep(for: Self.settle)
            busy = false
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            step()
        }
    }
}
