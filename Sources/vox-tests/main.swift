import Foundation
import VoxCore

// Юнит-тесты ReplacementEngine без XCTest/swift-testing:
// на машинах с одними Command Line Tools нет тестовых фреймворков,
// поэтому тесты — обычный исполняемый таргет: swift run vox-tests

var failures = 0
var checks = 0

func expect(
    _ actual: String, _ expected: String, _ note: String = "",
    file: String = #file, line: Int = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        let suffix = note.isEmpty ? "" : " (\(note))"
        print("FAIL line \(line)\(suffix):\n  got:      \(actual)\n  expected: \(expected)")
    }
}

let engine: ReplacementEngine = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // vox-tests
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // корень
        .appendingPathComponent("glossary.json")
    guard let glossary = try? Glossary.load(from: url) else {
        print("FAIL: cannot load glossary.json"); exit(1)
    }
    return ReplacementEngine(glossary: glossary)
}()

func apply(_ text: String) -> String { engine.apply(to: text) }

// MARK: - Базовые замены

do {  // simpleReplacement
        expect(apply("дибити упал"), "dbt упал")
        expect(apply("залей в бигквери"), "залей в BigQuery")
        expect(apply("напиши в слак"), "напиши в Slack")
    }

do {  // caseInsensitive
        expect(apply("Дибити упал"), "dbt упал")
        expect(apply("ЛАЙТДЭШ обновился"), "Lightdash обновился")
    }

do {  // canonicalCaseNormalization
        // ASR может выдать термин латиницей, но с кривым регистром
        expect(apply("Dbt собирает mart"), "dbt собирает mart")
        expect(apply("наш lightdash лежит"), "наш Lightdash лежит")
    }

    // MARK: - Падежные хвосты

do {  // caseEndings
        expect(apply("в лайтдэше"), "в Lightdash")
        expect(apply("в слаке"), "в Slack")
        expect(apply("из бигквери"), "из BigQuery")
        expect(apply("на стейджинге"), "на staging")
        expect(apply("в гитлабе"), "в GitLab")
        expect(apply("без докера"), "без Docker")
        expect(apply("в дебите"), "в dbt")
    }

do {  // endingsNotAppliedToVowelFinalStems
        // «дибити» несклоняемое: основа на гласную, хвосты не матчатся
        expect(apply("дибитик"), "дибитик")
    }

    // MARK: - Многословные варианты

do {  // multiWordReplacement
        expect(apply("создал мердж реквест"), "создал merge request")
        expect(apply("данные из биг квери"), "данные из BigQuery")
        expect(apply("подключил клод код к базе"), "подключил Claude Code к базе")
    }

do {  // multiWordWithEnding
        expect(apply("после мердж реквеста"), "после merge request")
        expect(apply("настроил клауд ран"), "настроил Cloud Run")
    }

do {  // hyphenatedVariants
        expect(apply("создал мердж-реквест"), "создал merge request")
        expect(apply("настрою си-д"), "настрою CI/CD")
    }

    // MARK: - Пунктуация и границы

do {  // punctuationPreserved
        expect(apply("запушил в гитлаб, потом в слак."), "запушил в GitLab, потом в Slack.")
        expect(apply("дашборд (в лайтдэше) готов!"), "dashboard (в Lightdash) готов!")
    }

do {  // wordBoundaries
        // «апи» не должно срабатывать внутри других слов
        expect(apply("капитан написал рапорт"), "капитан написал рапорт")
        // «даг» внутри слова
        expect(apply("на дагестанском форуме"), "на дагестанском форуме")
        // «пуш» внутри слова
        expect(apply("пушкин и пушистый кот"), "пушкин и пушистый кот")
    }

    // MARK: - Ложные срабатывания на обычных русских словах

do {  // commonRussianWordsUntouched
        let untouchable = [
            "потом обновил и запустил",  // не Python
            "как раз проверю",  // не CAC и не RAG
            "кладет данные в таблицу",  // не Claude / CloudWatch
            "прямо перед релизом",  // не prompt
            "раз в сутки",  // не RAG
            "у него рак",  // не RAG
            "в марте закончим",  // не mart
            "табло аэропорта",  // не Tableau (только через boost)
            "сиди дома",  // не CI/CD
            "метрика просела",  // не metric (только через boost)
            "он положил ключи", "команда согласилась",
            "скользкий пол",  // не skill/skil
            "дай мне пять минут",  // не DAG
            "я часто проверяю",  // не chart
            "если что, пиши",  // не ChatGPT
            "в меню настроек",  // не venv
            "все проверил",  // не S3
            "скролл пропал",  // не skill
            "это не нужно",  // не Notion
            "табло аэровокзала",  // не Tableau
            "довез посылку до офиса",  // не Docker
        ]
        for phrase in untouchable {
            expect(apply(phrase), phrase, "ложное срабатывание в: \(phrase)")
        }
    }

do {  // declinedCommonWordsUntouched
        // Падежные формы обычных слов тоже не должны цепляться
        expect(apply("нет марта в календаре"), "нет марта в календаре")
        expect(apply("говорим о метриках"), "говорим о метриках")
        expect(apply("два стейка на гриле"), "два стейка на гриле")
    }

    // MARK: - Русские глагольные формы остаются как есть

do {  // verbFormsUntouched
        // Замены работают от начала слова, приставочные глаголы не трогаем
        expect(apply("я задеплоил хотфикс"), "я задеплоил хотфикс")
        expect(apply("закоммитил и запушил"), "закоммитил и запушил")
    }

do {  // slangStaysRussian — согласовано 15.07.2026: сленг не переводим
        expect(apply("деплой прошел"), "деплой прошел")
        expect(apply("сделай коммит"), "сделай коммит")
        expect(apply("новый промпт готов"), "новый промпт готов")
        expect(apply("прокачай скиллы"), "прокачай скиллы")
        expect(apply("после коммита"), "после коммита")
        expect(apply("чарт обновился"), "чарт обновился")
        expect(apply("пуш в мастер"), "пуш в мастер")
    }

do {  // approvedConversions — а это по-прежнему переводится
        expect(apply("дименшн в модели"), "dimension в модели")
        expect(apply("дашборд готов"), "dashboard готов")
        expect(apply("собери даг"), "собери DAG")
        expect(apply("спроси у чат джипити"), "спроси у ChatGPT")
        expect(apply("сравним с чат-жпти"), "сравним с ChatGPT")
        expect(apply("запрос на скл"), "запрос на SQL")
        expect(apply("д бт пересобрался"), "dbt пересобрался")
        expect(apply("запрос на сквеле"), "запрос на SQL")
    }

    // MARK: - AI-термины и кириллические огрызки из реальных прогонов

do {  // realWorldLeftovers
        // Реальные огрызки из тестовых диктовок Этапа 1
        expect(apply("через мсп"), "через MCP")
        expect(apply("ллм сама пишет"), "LLM сама пишет")
        expect(apply("лм сама пишет"), "LLM сама пишет")
        expect(apply("метрики лтв"), "метрики LTV")
        expect(apply("данные из га4"), "данные из GA4")
        expect(apply("лежат в с3"), "лежат в S3")
        expect(apply("логи в клоудвоче"), "логи в CloudWatch")
        expect(apply("промт для клода"), "промт для Claude")
        expect(apply("добавил раг с эмбеддингами"), "добавил RAG с embedding")
    }

do {  // yoNormalization — ё в тексте нормализуется при сравнении
        expect(apply("зелёный дашборд"), "зелёный dashboard")
    }

    // MARK: - Крайние случаи

do {  // emptyAndNoMatches
        expect(apply(""), "")
        expect(apply("обычное предложение без терминов"), "обычное предложение без терминов")
    }

do {  // multipleReplacementsInOneSentence
        expect(apply("даг в эйрфлоу забирает из га4, кладет в с3, а дибити собирает витрину для лайтдэша"), "DAG в Airflow забирает из GA4, кладет в S3, а dbt собирает витрину для Lightdash")
    }

do {  // repeatedTerm
        expect(apply("слак упал, перезапусти слак"), "Slack упал, перезапусти Slack")
    }


if failures == 0 {
    print("OK: \(checks) checks passed")
} else {
    print("\(failures) of \(checks) checks FAILED")
    exit(1)
}
