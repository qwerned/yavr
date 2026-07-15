import ServiceManagement
import SwiftUI
import VoxCore

/// Табы окна настроек собираются в NSTabViewController (стиль системных
/// настроек macOS) — см. AppDelegate.openSettings. Здесь только контент вкладок.
/// Дизайн — по согласованному моку design/settings-redesign.html.

/// Высота всех вкладок одинаковая, чтобы окно не скакало.
let settingsTabSize = CGSize(width: 540, height: 780)

// MARK: - Общие элементы стиля

/// Цветная иконка строки, как в Системных настройках.
struct RowIcon: View {
    let system: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: system)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white))
    }
}

struct RowLabel: View {
    let icon: String
    let color: Color
    let text: String
    var sub: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            RowIcon(system: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                if let sub {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Подстрока без иконки: невидимый плейсхолдер тех же размеров, что RowIcon,
/// гарантирует выравнивание текста с обычными строками.
struct SubRowLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Color.clear.frame(width: 24, height: 24)
            Text(text)
        }
    }
}

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
                LabeledContent {
                    Picker("", selection: $triggerMode) {
                        Text("Модификатор").tag("hold")
                        Text("Сочетание").tag("toggle")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                } label: {
                    RowLabel(icon: "keyboard", color: .indigo, text: "Триггер")
                }

                if triggerMode == "hold" {
                    LabeledContent {
                        Picker("", selection: $holdModifier) {
                            Text("Правый Option (⌥)").tag("rightOption")
                            Text("Правый Command (⌘)").tag("rightCommand")
                            Text("Правый Control (⌃)").tag("rightControl")
                        }
                        .labelsHidden()
                    } label: {
                        SubRowLabel(text: "Клавиша")
                    }
                } else {
                    LabeledContent {
                        ShortcutRecorderField()
                    } label: {
                        SubRowLabel(text: "Сочетание клавиш")
                    }
                    LabeledContent {
                        Picker("", selection: $shortcutBehavior) {
                            Text("Держать и говорить").tag("hold")
                            Text("Нажал — старт, нажал — стоп").tag("toggle")
                        }
                        .labelsHidden()
                    } label: {
                        SubRowLabel(text: "Режим")
                    }
                }

                LabeledContent {
                    Picker("", selection: $microphoneUID) {
                        Text("Системный по умолчанию").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                } label: {
                    RowLabel(icon: "mic.fill", color: .red, text: "Микрофон")
                }

                LabeledContent {
                    Picker("", selection: $language) {
                        ForEach(Prefs.dictationLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                } label: {
                    RowLabel(icon: "globe", color: .blue, text: "Язык диктовки")
                }
            } header: {
                Text("Запись")
            } footer: {
                Text(
                    triggerMode == "hold"
                        ? "Удерживайте клавишу и говорите — отпустите, чтобы распознать."
                        : "Нажмите на сочетание, чтобы записать новое. Esc — отмена."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Picker("", selection: $insertMode) {
                        Text("В активное окно + буфер").tag("paste")
                        Text("Только в буфер обмена").tag("clipboard")
                    }
                    .labelsHidden()
                } label: {
                    RowLabel(icon: "doc.on.clipboard", color: .green, text: "Вставка")
                }
                Toggle(isOn: $showPopup) {
                    RowLabel(icon: "bubble.middle.bottom", color: .cyan, text: "Попап с результатом")
                }
            } header: {
                Text("Результат")
            } footer: {
                Text("Если вставка невозможна (пароль, нет разрешения) — результат остаётся в буфере.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Во время записи") {
                Toggle(isOn: $duckAudio) {
                    RowLabel(icon: "speaker.wave.2.fill", color: .orange, text: "Приглушать звук")
                }
                Toggle(isOn: $playSounds) {
                    RowLabel(icon: "music.note", color: .purple, text: "Звуки начала и конца")
                }
            }

            Section("Модель и система") {
                HStack {
                    RowLabel(
                        icon: "waveform", color: .indigo, text: "Модель распознавания",
                        sub: modelInstalled
                            ? "Parakeet v3 · установлена" : "Не установлена · 570 МБ")
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
                Toggle(isOn: $launchAtLogin) {
                    RowLabel(
                        icon: "rectangle.portrait.and.arrow.right", color: .gray,
                        text: "Запускать при входе")
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    applyLaunchAtLogin(enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: settingsTabSize.width, height: settingsTabSize.height)
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
    @State private var search = ""

    private var filteredTerms: [GlossaryTerm] {
        guard !search.isEmpty else { return store.glossary.terms }
        let q = search.lowercased()
        return store.glossary.terms.filter { term in
            term.text.lowercased().contains(q)
                || (term.replacements ?? []).contains { $0.lowercased().contains(q) }
                || (term.aliases ?? []).contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("СЛОВАРЬ ТЕРМИНОВ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("Поиск", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 130)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 4)

            List {
                ForEach(filteredTerms, id: \.text) { term in
                    TermRow(term: term) { updated in
                        replaceTerm(old: term.text, with: updated)
                    } onDelete: {
                        removeTerm(term.text)
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            Text("Замены — «как слышится → как писать», работают всегда. Бустинг — распознавание по звучанию; выключайте, если термин ловит обычные слова.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

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
                .padding(.horizontal, 4)
        }
        .padding(18)
        .frame(width: settingsTabSize.width, height: settingsTabSize.height)
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

/// Строка термина: свёрнуто — сводка; раскрыто — редактор замен и бустинга.
private struct TermRow: View {
    let term: GlossaryTerm
    let onUpdate: (GlossaryTerm) -> Void
    let onDelete: () -> Void

    @State private var variantsText = ""
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
                    LabeledContent("Алиасы (как звучит)") {
                        TextField("как звучит, через запятую", text: $aliasesText)
                            .textFieldStyle(.roundedBorder)
                            .focused($aliasesFocused)
                            .onSubmit(commit)
                    }
                    LabeledContent("Порог схожести") {
                        Picker("", selection: $threshold) {
                            Text("Авто").tag(0.0)
                            Text("0.7").tag(0.7)
                            Text("0.75").tag(0.75)
                            Text("0.8").tag(0.8)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: threshold) { _, _ in commit() }
                    }
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
                    .frame(width: 118, alignment: .leading)
                Text(variantsText.isEmpty ? "без замен" : variantsText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if boostEnabled {
                    Image(systemName: "waveform")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                        .help("Бустинг включён")
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
        }
        .onAppear(perform: load)
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
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            Text("YAVR")
                .font(.title2.bold())
            Text("Yet Another Voice Recognition · \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Голосовая диктовка с распознаванием IT-терминов.\nВсё распознавание — на этом Mac, без внешних сервисов.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Divider().padding(.vertical, 10).padding(.horizontal, 60)

            Text("Использует")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                Link(
                    "FluidAudio — Apache License 2.0",
                    destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                Link(
                    "NVIDIA Parakeet TDT 0.6b v3 (CoreML) — CC-BY-4.0",
                    destination: URL(
                        string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
            }
            .font(.caption)

            Button("Пройти настройку заново…") {
                (NSApp.delegate as? AppDelegate)?.openOnboarding()
            }
            .padding(.top, 14)
            Spacer()
        }
        .frame(width: settingsTabSize.width, height: settingsTabSize.height)
    }
}
