import Foundation

/// Статистика диктовок: дневные агрегаты в Application Support/Vox/stats.json.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    struct DayStats: Codable {
        var transcriptions: Int = 0
        var characters: Int = 0
        var words: Int = 0
    }

    struct Totals {
        var transcriptions = 0
        var characters = 0
        var words = 0

        mutating func add(_ day: DayStats) {
            transcriptions += day.transcriptions
            characters += day.characters
            words += day.words
        }
    }

    /// Ключ — «yyyy-MM-dd» в локальной таймзоне.
    @Published private(set) var days: [String: DayStats] = [:]

    private let fileURL: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vox/stats.json")
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        load()
    }

    func record(text: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let key = Self.dayFormatter.string(from: Date())
        var day = days[key] ?? DayStats()
        day.transcriptions += 1
        day.characters += text.count
        day.words += words
        days[key] = day
        save()
    }

    // MARK: - Агрегаты

    func totals(from startDate: Date?) -> Totals {
        var result = Totals()
        for (key, day) in days {
            guard let date = Self.dayFormatter.date(from: key) else { continue }
            if let startDate, date < Calendar.current.startOfDay(for: startDate) { continue }
            result.add(day)
        }
        return result
    }

    var today: Totals { totals(from: Date()) }
    var last7Days: Totals {
        totals(from: Calendar.current.date(byAdding: .day, value: -6, to: Date()))
    }
    var thisMonth: Totals {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return totals(from: Calendar.current.date(from: comps))
    }
    var allTime: Totals { totals(from: nil) }

    /// Последние 30 дней для графика: (короткая дата, слова).
    var last30Days: [(label: String, date: String, words: Int)] {
        let calendar = Calendar.current
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else {
                return nil
            }
            let key = Self.dayFormatter.string(from: date)
            let day = calendar.component(.day, from: date)
            let month = calendar.component(.month, from: date)
            return ("\(day).\(String(format: "%02d", month))", key, days[key]?.words ?? 0)
        }
    }

    /// «1 ч 48 м» из числа слов при заданной скорости печати (слов/мин).
    static func savedTime(words: Int, wpm: Int) -> String {
        guard wpm > 0 else { return "—" }
        let minutes = words / wpm
        if minutes < 1 { return "<1 мин" }
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }

    // MARK: - Диск

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data)
        else { return }
        days = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(days) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
