# Первичные источники

[Оглавление](README.md)

Проверены при подготовке проекта 18 октября 2026 года. Документация и ветки репозиториев могут измениться: перед подключением зависимости фиксировать tag/commit и `Package.resolved`. Перечисленные источники подтверждают возможности технологий; конкретная архитектура и критерии проекта — проектные решения.

| Источник | Для чего используется |
|---|---|
| [SwiftUI NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) | Структура боковой панели и содержимого |
| [Observation](https://developer.apple.com/documentation/observation) | Наблюдаемое UI-состояние |
| [Swift concurrency](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/) | Изоляция данных и асинхронные операции |
| [Swift 6 migration](https://www.swift.org/migration/) | Проверка data races в language mode 6 |
| [GRDB README](https://github.com/groue/GRDB.swift) и [Package.swift v7.11.1](https://github.com/groue/GRDB.swift/blob/v7.11.1/Package.swift) | SQLite, миграции, наблюдение, транзакции; кандидат версии требует Swift tools 6.1 |
| [SQLite FTS5](https://www.sqlite.org/fts5.html) | Поисковый индекс; его наличие проверить в выбранной системной SQLite |
| [SQLite Online Backup API](https://www.sqlite.org/backup.html) | Согласованная копия БД, вместо копирования одного открытого файла WAL-базы |
| [swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) | Swift-адаптер планировщика; отдельно проверяется конфигурация FSRS-6 |
| [fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs) | Независимый источник для сравнения контрольных расчётов, не обязательная runtime-зависимость |
| [Swift Charts](https://developer.apple.com/documentation/charts) | Графики с локализацией и доступностью |
| [Speech synthesis](https://developer.apple.com/documentation/avfoundation/speech-synthesis) | Произношение системным синтезом речи |
| [Local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) | Системное расписание локальных напоминаний |
| [Files in macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | Доступ к выбранным пользователем папкам и файлам |
| [Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | Прямое распространение приложения |
| [Swift Testing](https://developer.apple.com/documentation/testing) | Модульные и параметризованные тесты |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | Чтение/создание ZIP-контейнера, не готовая реализация APKG |
| [Anki export](https://docs.ankiweb.net/manual/exporting) | Пакеты колод/коллекций, варианты экспорта и наличие истории |
| [Anki packaged decks](https://docs.ankiweb.net/manual/importing/packaged-decks) | Содержимое пакетов, повторный импорт и прогресс |

Локальные источники продукта: [manifest.json](../design-references/manifest.json), [все состояния](../design-references/STATES.md), [правила переходов](../design-references/FLOWS.md), [визуальная система](../design-references/DESIGN.md). Автоматическая генерация изображений не является источником технической корректности API, алгоритмов и форматов файлов.

## Последовательная работа разными чатами

[AGENTS.md — официальные инструкции Codex](https://developers.openai.com/codex/guides/agents-md), [Xcode command-line reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference), [Swift extension для VS Code](https://docs.swift.org/latest/documentation/userdocs/). Личный режим работы зафиксирован пользователем 18 октября 2026 года.
