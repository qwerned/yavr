import Charts
import SwiftUI

/// Вкладка «Статистика»: карточки за периоды + слова за 30 дней.
struct StatsTab: View {
    @ObservedObject private var stats = StatsStore.shared
    @AppStorage(Prefs.Key.typingSpeed) private var typingSpeed = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("СТАТИСТИКА")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                spacing: 12
            ) {
                StatCard(title: "Сегодня", totals: stats.today, wpm: typingSpeed)
                StatCard(title: "За 7 дней", totals: stats.last7Days, wpm: typingSpeed)
                StatCard(title: "Этот месяц", totals: stats.thisMonth, wpm: typingSpeed)
                StatCard(title: "За всё время", totals: stats.allTime, wpm: typingSpeed)
            }

            Text("СЛОВА ЗА 30 ДНЕЙ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 6)

            Chart(stats.last30Days, id: \.date) { item in
                BarMark(
                    x: .value("День", item.label),
                    y: .value("Слова", item.words)
                )
                .foregroundStyle(.tint)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(preset: .aligned) { value in
                    if value.index % 5 == 0 {
                        AxisValueLabel()
                    }
                    AxisGridLine().foregroundStyle(.clear)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                RowLabel(
                    icon: "gauge.with.needle", color: .orange, text: "Скорость печати",
                    sub: "для расчёта сэкономленного времени")
                Spacer()
                Stepper(value: $typingSpeed, in: 10...300, step: 10) {
                    Text("\(typingSpeed) слов/мин")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(width: settingsTabSize.width, height: settingsTabSize.height)
    }
}

private struct StatCard: View {
    let title: String
    let totals: StatsStore.Totals
    let wpm: Int

    private var savedLabel: String {
        let time = StatsStore.savedTime(words: totals.words, wpm: wpm)
        return time.hasPrefix("<") ? time : "~" + time
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(totals.words)")
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
            Text("слов · сэкономлено \(savedLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("Диктовок: \(totals.transcriptions)")
                Text("Знаков: \(totals.characters)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
