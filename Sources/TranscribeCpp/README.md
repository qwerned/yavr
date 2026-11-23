# TranscribeCpp

Swift-обёртка [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
версии 0.4.1 (коммит 4d7c1cc, `bindings/swift/Sources/TranscribeCpp`), без
изменений. Лицензия MIT — см. `LICENSE`. Нативная часть (`CTranscribe`) —
`TranscribeCpp.xcframework.zip` из релиза v0.4.1, подключена в `Package.swift`.

Обновление: заменить файлы из нового тега и поправить url/checksum в
`Package.swift`; версии обёртки и xcframework должны совпадать
(`Transcribe.ensureCompatible()` проверяет ABI при загрузке модели).
