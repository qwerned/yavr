import Foundation

/// Пути приложения. Данные — в ~/Library/Application Support/YAVR.
///
/// До переименования приложение называлось Vox и писало в каталог `Vox`.
/// При первом запуске новой версии старый каталог переезжает целиком
/// (словарь и статистика сохраняются), новый каталог не трогаем.
enum AppPaths {
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            "Library/Application Support/YAVR", isDirectory: true)
        let legacy = home.appendingPathComponent(
            "Library/Application Support/Vox", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var glossaryFile: URL { supportDirectory.appendingPathComponent("glossary.json") }
    static var statsFile: URL { supportDirectory.appendingPathComponent("stats.json") }
}
