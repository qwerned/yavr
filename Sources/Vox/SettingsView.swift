import ServiceManagement
import SwiftUI
import VoxCore

/// Табы окна настроек собираются в NSTabViewController (стиль системных
/// настроек macOS) — см. AppDelegate.openSettings. Здесь только контент вкладок.

// MARK: - Основные

struct GeneralTab: View {
    @AppStorage(Prefs.Key.triggerMode) private var triggerMode = "hold"
    @AppStorage(Prefs.Key.holdModifier) private var holdModifier = "rightOption"
    @AppStorage(Prefs.Key.insertMode) private var insertMode = "paste"
    @AppStorage(Prefs.Key.microphoneUID) private var microphoneUID = ""
    @AppStorage(Prefs.Key.playSounds) private var playSounds = true
    @AppStorage(Prefs.Key.showPopup) private var showPopup = true
    @AppStorage(Prefs.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Prefs.Key.language) private var language = "ru"
    @AppStorage(Prefs.Key.shortcutBehavior) private var shortcutBehavior = "hold"
    @AppStorage(Prefs.Key.duckAudio) private var duckAudio = true

    @State private var devices: [AudioDevices.Device] = []
    @State private var modelInstalled = TranscriptionService.modelsInstalled()
    @State private var downloading = false
    @State private var downloadProgress = 0.0

    var body: some View {
        Form {
            Section {
                Picker("Триггер записи", selection: $triggerMode) {
                    Text("Удерживать модификатор").tag("hold")
                    Text("Кастомное сочетание").tag("toggle")
                }
                Picker("Модификатор", selection: $holdModifier) {
                    Text("Правый Option (⌥)").tag("rightOption")
                    Text("Правый Command (⌘)").tag("rightCommand")
                    Text("Правый Control (⌃)").tag("rightControl")
                }
                .disabled(triggerMode != "hold")
                LabeledContent {
                    ShortcutRecorderField()
                        .disabled(triggerMode != "toggle")
                } label: {
                    Text("Сочетание клавиш")
                }
                Picker("Режим сочетания", selection: $shortcutBehavior) {
                    Text("Держать и говорить").tag("hold")
                    Text("Нажал — старт, нажал — стоп").tag("toggle")
                }
                .disabled(triggerMode != "toggle")
                Picker("Микрофон", selection: $microphoneUID) {
                    Text("Системный по умолчанию").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Язык диктовки", selection: $language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            }

            Section {
                Picker("Результат диктовки", selection: $insertMode) {
                    Text("Вставлять в активное окно").tag("paste")
                    Text("Только копировать в буфер").tag("clipboard")
                }
                .pickerStyle(.radioGroup)
                if insertMode == "paste" {
                    Text("Копия остаётся в буфере обмена. Если вставка невозможна — только буфер.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(modelInstalled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Модель распознавания")
                        Text(
                            modelInstalled
                                ? "Parakeet v3 + словарная модель · установлена"
                                : "Не установлена · 570 МБ"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if downloading {
                        ProgressView(value: downloadProgress)
                            .frame(width: 120)
                    } else {
                        Button(modelInstalled ? "Скачать заново" : "Скачать") {
                            downloadModels()
                        }
                    }
                }
            }

            Section {
                Toggle("Приглушать звук при записи", isOn: $duckAudio)
                Toggle("Звуки начала и конца записи", isOn: $playSounds)
                Toggle("Показывать попап с результатом", isOn: $showPopup)
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520, height: 614)
        .onAppear { devices = AudioDevices.inputDevices() }
    }

    private func downloadModels() {
        downloading = true
        downloadProgress = 0
        Task {
            do {
                try await TranscriptionService.shared.downloadModels { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    downloading = false
                    modelInstalled = TranscriptionService.modelsInstalled()
                }
            } catch {
                await MainActor.run { downloading = false }
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        // Работает только из собранного .app-бандла; при dev-запуске молча пропускаем
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
    }
}

// MARK: - Словарь

struct DictionaryTab: View {
    @ObservedObject private var store = GlossaryStore.shared
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Термины")
                .font(.headline)
            Text("Каноническое написание, кириллические варианты «как слышится» — через запятую. Сохраняется по Enter или при уходе из поля.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.glossary.terms, id: \.text) { term in
                    TermRow(term: term) { updated in
                        replaceTerm(old: term.text, with: updated)
                    } onDelete: {
                        removeTerm(term.text)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)

            HStack {
                TextField("Новый термин (например, Kubernetes)", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Добавить", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Файл: ~/Library/Application Support/Vox/glossary.json — можно править и руками.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 520, height: 614)
        // Подхватываем внешние правки файла, чтобы сохранение из UI их не затёрло
        .onAppear { store.reload() }
    }

    private func addTerm() {
        let text = newTerm.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
            !store.glossary.terms.contains(where: { $0.text.lowercased() == text.lowercased() })
        else { return }
        var terms = store.glossary.terms
        terms.append(GlossaryTerm(text: text, aliases: [], replacements: []))
        store.save(Glossary(minTermLength: store.glossary.minTermLength, terms: terms))
        newTerm = ""
    }

    private func removeTerm(_ text: String) {
        let terms = store.glossary.terms.filter { $0.text != text }
        store.save(Glossary(minTermLength: store.glossary.minTermLength, terms: terms))
    }

    private func replaceTerm(old: String, with updated: GlossaryTerm) {
        var terms = store.glossary.terms
        if let index = terms.firstIndex(where: { $0.text == old }) {
            terms[index] = updated
            store.save(Glossary(minTermLength: store.glossary.minTermLength, terms: terms))
        }
    }
}

/// Строка термина: каноническое написание + редактируемые варианты + удаление.
private struct TermRow: View {
    let term: GlossaryTerm
    let onUpdate: (GlossaryTerm) -> Void
    let onDelete: () -> Void

    @State private var variantsText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term.text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 120, alignment: .leading)
            TextField("как слышится, через запятую", text: $variantsText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Удалить термин")
        }
        .onAppear {
            let all = (term.replacements ?? [])
            variantsText = all.joined(separator: ", ")
        }
    }

    private func commit() {
        let variants = variantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Варианты идут и в замены, и в акустические алиасы
        onUpdate(
            GlossaryTerm(
                text: term.text,
                aliases: mergedAliases(with: variants),
                minSimilarity: term.minSimilarity,
                replacements: variants))
    }

    private func mergedAliases(with variants: [String]) -> [String] {
        var result = term.aliases ?? []
        for variant in variants where !result.contains(variant) {
            result.append(variant)
        }
        return result
    }
}

// MARK: - О программе

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("YAVR")
                .font(.title2.bold())
            Text("Yet Another Voice Recognition.\nГолосовая диктовка с распознаванием IT-терминов.\nВсё распознавание — на этом Mac, без внешних сервисов.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 6)

            VStack(spacing: 4) {
                Text("Использует:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    "FluidAudio — Apache License 2.0",
                    destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                Link(
                    "NVIDIA Parakeet TDT 0.6b v3 (CoreML) — CC-BY-4.0",
                    destination: URL(
                        string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(width: 520, height: 614)
    }
}
