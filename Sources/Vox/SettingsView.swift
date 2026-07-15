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
            Text("Кликните по термину, чтобы настроить замены и акустический бустинг. Сохраняется по Enter или при уходе из поля.")
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
    @State private var aliasesText = ""
    @State private var boostEnabled = false
    @State private var threshold = 0.0  // 0 = авто
    @State private var expanded = false
    @FocusState private var replacementsFocused: Bool
    @FocusState private var aliasesFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Замены") {
                    TextField("как слышится, через запятую", text: $variantsText)
                        .textFieldStyle(.roundedBorder)
                        .focused($replacementsFocused)
                        .onSubmit(commit)
                }
                Toggle("Акустический бустинг", isOn: $boostEnabled)
                    .onChange(of: boostEnabled) { _, _ in commit() }
                if boostEnabled {
                    LabeledContent("Алиасы") {
                        TextField("как звучит, через запятую", text: $aliasesText)
                            .textFieldStyle(.roundedBorder)
                            .focused($aliasesFocused)
                            .onSubmit(commit)
                    }
                    Picker("Порог схожести", selection: $threshold) {
                        Text("Авто").tag(0.0)
                        Text("0.7").tag(0.7)
                        Text("0.75").tag(0.75)
                        Text("0.8 (строгий)").tag(0.8)
                    }
                    .onChange(of: threshold) { _, _ in commit() }
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .padding(.leading, 4)
            .onChange(of: replacementsFocused) { _, f in if !f { commit() } }
            .onChange(of: aliasesFocused) { _, f in if !f { commit() } }
        } label: {
            HStack(spacing: 8) {
                Text(term.text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 120, alignment: .leading)
                if boostEnabled {
                    Image(systemName: "waveform")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                        .help("Бустинг включён")
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
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
        }
        .onAppear(perform: load)
    }

    private var summary: String {
        let repl = variantsText.isEmpty ? "без замен" : variantsText
        return repl
    }

    private func load() {
        variantsText = (term.replacements ?? []).joined(separator: ", ")
        aliasesText = (term.aliases ?? []).joined(separator: ", ")
        boostEnabled = !(term.aliases ?? []).isEmpty
        threshold = term.minSimilarity.map { Double($0) } ?? 0.0
    }

    private func parse(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commit() {
        let aliases = boostEnabled ? parse(aliasesText) : []
        onUpdate(
            GlossaryTerm(
                text: term.text,
                aliases: aliases,
                minSimilarity: threshold == 0 ? nil : Float(threshold),
                replacements: parse(variantsText)))
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
