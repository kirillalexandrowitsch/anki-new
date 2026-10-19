# Воспроизводимые проверки T012

[Качество](QUALITY.md) · [Каркас](APP_SCAFFOLD.md) · [Зависимости](DEPENDENCIES.md) · [Бюджет](BUDGET.md)

Из корня проекта на Apple Silicon Mac с полным Xcode:

```sh
# Подготовка точных зависимостей; может обращаться к сети.
python3 scripts/check.py --resolve

# Обычный цикл: package tests + Debug app build, без resolve/update.
python3 scripts/check.py

# Приёмка: два запуска на свежих временных коллекциях с запретом сети ОС.
python3 scripts/check.py --deny-network
python3 scripts/check.py --deny-network

# Дополнительно app unit/UI tests вместо одной сборки; нужен графический сеанс.
python3 scripts/check.py --app-tests
python3 scripts/ci.py quality
```

`--resolve` подготавливает SwiftPM `.build/checkouts` и Xcode `build/check-packages`.
До тестов сверяются наличие всех checkout и их HEAD с обоими committed `Package.resolved`.
При отсутствии cache или другой revision запуск завершается ошибкой; resolve надо выполнить
явно. Обычный запуск использует `--skip-update --disable-automatic-resolution` для SwiftPM
и `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`
для Xcode. `--deny-network` дополнительно применяет системный `sandbox-exec` с
`(deny network*)` ко всему дереву процессов каждого проверочного шага. В этом режиме
вложенный sandbox manifests выключен через SwiftPM `--disable-sandbox` и Xcode
`-IDEPackageSupportDisableManifestSandbox=YES`, а sandbox compiler macros — через
Swift compiler `-disable-sandbox`, поскольку macOS
запрещает вложенный `sandbox-exec`; внешний запрет сети остаётся. Недоступный sandbox
даёт ошибку проверки.

`ci.py macos` на стандартном бесплатном public macos-15 runner запускает тот же
`check.py --resolve --app-tests`: подготовка, все package tests и app unit/UI tests.
Оба обязательных job `quality`/`macos` сохранены, uploads artifacts/cache не добавлены.
Локальная ad-hoc сборка не требует Apple Account или платной Developer Program.
Скрипт поддерживает единственный зарегистрированный пакет CardsKit; появление других
пакетов требует расширить проверку, иначе конфигурация отклоняется.

## Данные, время и сбои

Версионированный набор: `Packages/CardsKit/Tests/CardsInfrastructureTests/Fixtures/synthetic-v1/`.
Seed **12**, время **1792368000000 ms UTC**, стабильные UUID namespace
`00000000-0012-4000-8000-*`, три колоды с иерархией, четыре Note, пять Card.
Есть new/learning/review/relearning, сроки до/на/после заданного времени, suspended,
кириллица/ё/диакритика и Note с двумя вариантами. PNG 1×1 — фиксированные синтетические
байты; WAV — сгенерированный PCM-сигнал 8 kHz mono, не запись микрофона. SHA-256 обоих
файлов хранится в seed; тест декодирует их системными API.

`SyntheticFixture` применяет настоящие migrations к новой временной file-БД, заполняет
SQL транзакционно, копирует immutable media и проверяет хеши. Это только test seeding;
реализация Note Save не подразумевается. Scheduler parameter row — минимальный storage
stub, для расчётов FSRS используются отдельные точные reference fixtures T003.
Логический fingerprint seeded SQL-строк и media исключает page layout, WAL и абсолютные
пути. Он закреплён в `fingerprint.sha256`:

```text
b26e3aaf1403290e361fffd5d3c5c6cab64780d079420a80632560d2763b4e86
```

Тест сравнивает две независимо созданные БД, committed fingerprint и reopen.
Скрипт требует этот fingerprint в package tests: пропуск fixture-теста или незаметное
изменение данных не проходит. Порядок тестов и UUID временных директорий не влияют
на значения; длительности и порядок stdout могут различаться.

`CardsTestSupport` — внутренний target под `Tests/Support`, не продукт пакета и не
зависимость production targets. Он содержит потокобезопасный управляемый `TestClock`,
`TestDirectory` с правами 0700 и удалением при освобождении, `FaultProbe` с выбранной
точкой/номером срабатывания. Core/Features tests используют общий clock. Infrastructure
проверяет rollback mutation + processed command и media recovery через существующие hooks.
Migration/media/backup hooks остаются internal, доступны через `@testable`; новых
production-переключателей ошибок нет.

Тесты используют synthetic resources и отдельные temporaryDirectory. App tests используют
`CollectionTestID` из shared scheme; UI tests задают свой временный UUID. Скрипт удаляет
унаследованные `ANKI_*` из окружения subprocess, чтобы crash-runner не принял внешний
ANKI_BACKUP_TEST_ROOT/ARCHIVE за свой контекст. Crash-тест сам передаёт эти переменные
дочернему процессу со своим временным путём. Личная Application Support не открывается;
обычный check собирает `.app`, не запускает её вне тестового режима.

На локальной macOS 27.0.1 воспроизведён ложный `fts5: checksum mismatch` на reader,
который проверял пустой индекс до заполнения через writer. Новый reader и writer
подтверждали целостность тех же байтов. `CollectionDatabase.checkIntegrity()` теперь
выполняет полные integrity/foreign key checks и явную FTS5 `integrity-check` команду
в одной транзакции на writer: у неё INSERT-синтаксис, хотя данные не меняются.
На SQLite runner macos-15 PRAGMA ещё не обнаруживает FTS checksum corruption;
явная команда проверяет индекс и на этой версии.
Регрессия проверяет новый commit; намеренно повреждённый shadow content через системный
sqlite3 по-прежнему отклоняется. Схема/migrations не меняются. Контракт FTS consistency:
[документация SQLite](https://www.sqlite.org/fts5.html#the_integrity_check_command).

## Безопасная диагностика

Каждый запуск сохраняет `build/checks/run-*/summary.json`, включая неуспешный: фаза,
фиксированная команда, exit code, известные имена тестовых функций, source-файл без пути
и номера строк/колонок, категории ошибок, числа тестов, synthetic fingerprint.
Timeout останавливает дерево subprocess. Свободные сообщения, assertion values, SQL,
тексты карточек, пользовательские пути, environment и raw stdout/stderr не копируются.
Временный xcresult `--app-tests` удаляется и при провале; остаётся техническая сводка.
Build intermediates в игнорируемом `build/check-derived` не являются диагностическим
экспортом и не публикуются. Ошибку воспроизводить по phase/test ID/source location на fixture.

`scripts/test_check.py` реально запускает child с exit 17 и чувствительными на вид
строками: JSON сохраняет location/test ID, но не эти строки. Отдельно проверяются timeout,
отсутствующий инструмент, whitelist имён и отсутствие cache. Даже preflight не выводит
exception string. `build/`, xcresult и временные SQLite не коммитятся. Новых зависимостей,
платных API/подписок и использования личных данных нет.
