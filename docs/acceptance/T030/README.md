# T030 · Приёмка первой рабочей вертикали

Дата: 23 октября 2026, Europe/Moscow. Проверена версия task/T030 от
origin/dev `590fdd0` с двумя новыми сквозными тестами. Результат — принята
рабочая вертикаль M1. Полный дизайн и функции M2–M5 этой приёмкой не заявляются.
Точные commits и результаты доставки доступны в Git/PR; этот протокол не содержит
ссылки на собственный будущий commit.

## Среда и изоляция

Локальный Mac Apple Silicon, Xcode, ad-hoc подпись, Release Mach-O arm64.
Сборка использует обычную конфигурацию Release с единственным изменением
bundle ID: `local.anki-new.acceptance.T030`. Это отдельные sandbox container,
Application Support и UserDefaults; личная коллекция не открывалась.
Debug XCUITest использует новый UUID `-CollectionTestID` и отдельную временную
коллекцию. Интеграционный тест использует удаляемые временные директории.

Новых зависимостей, подписок, AI API, uploads/cache в CI нет. Исходные
дизайн-референсы не изменены. В Git включены только тесты, протокол,
синтетические снимки и отчёт задачи. SQLite, CSV, архивы, xcresult и логи
остаются локально в ignored `build/` или `/tmp/`.

## Фактические проверки

| Проверка | Команда / процедура | Результат |
|---|---|---|
| Новый интеграционный сценарий | `swift test --package-path Packages/CardsKit --skip-update --disable-automatic-resolution --filter firstVertical` | Passed, 1 тест. Реальные file-backed commands создания колоды/четырёх Notes с tags/examples/Unicode/multiline/shared PNG; четыре grade; повтор каждой команды; stats; close/open; CSV; backup/restore в другую коллекцию; повторный open. |
| Полный offline прогон | `python3 scripts/check.py --deny-network` | Passed; `build/checks/run-86ikilau/summary.json`, `networkDenied=true`. Core 30, Infrastructure 153, Features 30, DesignSystem 3 и XCTest worker 1; app build passed. Fixture seed12 SHA-256 `b26e3aaf1403290e361fffd5d3c5c6cab64780d079420a80632560d2763b4e86`. |
| XCUITest smoke | `xcodebuild test -project AnkiNew.xcodeproj -scheme AnkiNew -destination 'platform=macOS,arch=arm64' -derivedDataPath build/check-derived -clonedSourcePackagesDirPath build/check-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -only-testing:AnkiNewUITests/AppShellUITests/testFirstVerticalCreateFourGradesStatisticsAndReopen -resultBundlePath build/T030-smoke.xcresult` | TEST SUCCEEDED; 1 тест, 0 failures. Лог `/tmp/anki-T030-smoke.log`; screenshots вложены в локальный xcresult, CI их не загружает. |
| Release build | `xcodebuild -project AnkiNew.xcodeproj -scheme AnkiNew -configuration Release build -destination 'platform=macOS,arch=arm64' -derivedDataPath build/T030-release -clonedSourcePackagesDirPath build/check-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PRODUCT_BUNDLE_IDENTIFIER=local.anki-new.acceptance.T030` | BUILD SUCCEEDED; `file …/AnkiNew.app/Contents/MacOS/AnkiNew` подтверждает arm64; локальный запуск через native CUA. |
| Ручная Release приёмка | Ниже, нативные контролы/меню/NSSavePanel, затем Cmd-Q и запуск того же .app | Passed; сохранены снимки окна/диалогов, без других приложений. |

Финальный повтор smoke вместе с `testExportNativeSavePanelCancelAndVerifiedCSVSuccess`
также прошёл: 2 tests, 0 failures, `build/T030-smoke-final.xcresult`,
лог `/tmp/anki-T030-smoke-final.log`. Smoke учитывает наступление срока Again
на медленной машине через штатное досрочное завершение после четырёх оценок.
Финальный полный offline повтор: `build/checks/run-fk_d3b4u/summary.json`,
все проверки passed, 216 Swift Testing tests и XCTest worker 1.
`tasks.py finish/check`, `ci.py quality` и `git diff --check` passed:
26 Python tests, 2492 local links, 48/48 оригинальных design PNG.

Первый compile интеграционного теста обнаружил неправильный тип query port:
`CollectionQueryService` не содержит statistics. Исправлено использование
`StatsWorkspace.queries`, после чего целевой и полный offline прогоны passed.

Внешний `sandbox-exec (deny network*)` вокруг sandboxed Release завершился
SIGTRAP при старте (локальный диагностический отчёт); этот запуск не засчитан.
Обычный Release запущен штатно с App Sandbox и без network client/server
entitlements. Жёсткий OS deny-network для package tests и сборки подтверждён
отдельным `check.py`; сетевые настройки владельца не менялись.

## Ручной сценарий Release

1. Запуск из `build/T030-release/Build/Products/Release/AnkiNew.app`. Welcome
   пустой коллекции → создать `Synthetic T030 Release` с явно выбранными
   тремя демо Notes. Сегодня показывает новые=3, оценок=0.
2. Библиотека → Добавить карточку. Введены front `Offline, "café"` и back
   `Перевод` + LF + `вторая строка`; явный Save. Счётчики становятся
   Card=4, Note=4. Колоды показывают ровно одну колоду с четырьмя Card.
3. Сегодня показывает новые=4. Начать настоящее занятие (не «Пробное»).
   На скрытой Hello нажата `1`: счётчик остаётся 0, grade-кнопок нет.
   Reveal показывает перевод и ровно четыре оценки.
4. Hello → Снова; Good morning → Трудно; Thank you → Хорошо;
   `Offline, "café"` → Легко. Каждый следующий вопрос скрыт;
   счётчик 0→1→2→3→4. Итог: 4 оценки, 4 Card, [1,1,1,1].
   Для Again отображается следующий срок, а не обещание, что всё выучено.
5. Статистика: 4 оценки, 4 уникальных Card, 75% успешных,
   активное время/время ответов 4 s, [1,1,1,1], один реальный столбец
   за сегодняшний день. Cmd-Q → повторный запуск: те же значения;
   Today сохраняет оценки и показывает наступившее обучение Again.
6. File → Экспортировать → CSV → NSSavePanel в
   `/tmp/anki-T030-release-export/Collection.csv`. Успех показан после записи.
   Независимая проверка Python `csv.reader`: заголовок 9 колонок, 4 строки;
   кавычки, café и LF в back совпадают с вводом.
7. То же меню → Cardsbackup: прогресс/медиа включены и недоступны для
   исключения. Сохранён `Collection.cardsbackup`. Проверены SHA-256/byteCount
   каждого payload. После закрытия .app все строки во всех 28 SQL-таблицах
   source (read-only SQLite с WAL) совпали с архивной collection.sqlite:
   4 review_logs, 4 card_schedules. SHA-256 архива:
   `61f86df8cc966ea468c2ce5a52fcb9469c6baf9a0e6cdd09bae7a58ad781c22d`.
8. Открыты Settings и распределение оценок; снимки сохранены. Приложение
   закрыто; тестовая коллекция/экспорты остаются локально для воспроизведения.

Точное **применение restore** проверяет интеграционный тест через штатный
`CollectionStore.restoreBackup` в другой, изначально пустой коллекции. Он
сравнивает каждую колонку каждой строки всех таблиц (включая schedules,
reviews, sessions, command journal, settings, search indexes), идентичность
коллекции, исходные Note contents и байты media, а затем повторно открывает
восстановленную коллекцию и повторяет сравнение. Это сервисная проверка;
пользовательского мастера восстановления в M1 пока нет.

## Потеря данных и двойная оценка

Незакрытых дефектов этих классов в проверенном объёме не обнаружено.
Новый тест посылает каждую из четырёх grade-команд дважды, но получает
строго 4 эффективные оценки и 4 уникальные Card. Новый XCUITest дополнительно
посылает grade key до каждого reveal и проверяет неизменный счётчик.
Существующие тесты полного offline прогона покрывают concurrent double
submission, разные команды с stale revision, rollback до commit, потерянный
acknowledgement + reopen, process crash до/после commit, atomic Undo и его
replay, checkpoint failure и restart. Это не утверждение отсутствия всех
возможных ошибок, а результат конкретных воспроизводимых проверок.

## Снимки и отличия от дизайна

Снимки получены с настоящей Release-сборки, без дорисовки или изменения
оригинальных референсов. Тёмная системная тема, окно 1100×760; sheets сняты
отдельно. Нижняя часть статистики доступна прокруткой.

| Область | Фактический снимок | Отличия / оставшаяся работа |
|---|---|---|
| Today / base-01, sheet-01 | [Сегодня](screenshots/release-today.png) | Системные cards/counts без большой иллюстрации, right-column progress/heatmap; глобальный поиск/слово дня T034, центр уведомлений T035. |
| Decks / base-02 | [Колоды](screenshots/release-decks.png) | Простой список и редактор; ещё нет полного дерева/grid/filter/inspector по референсу, развитие T031–T033. |
| Statistics / base-03 | [Статистика](screenshots/release-statistics.png), [распределение](screenshots/release-statistics-grades.png), [после запуска](screenshots/release-statistics-reopened.png) | Реальные totals/activity/grade counts, без модельного retention, donut, heatmap/forecast и сравнений периодов; дальнейшие T042/T043. Успешные ответы подписаны отдельно от вероятности воспоминания. |
| Library / base-04 | [Библиотека](screenshots/release-library.png) | Системная Table, поиск и optional inspector вместо полного layout с filters/tags/history/bulk. Столбец направления может требовать горизонтальной прокрутки при 1100 px; данные сохранены. T038–T041 расширяют библиотеку. |
| Settings / base-05 | [Настройки](screenshots/release-settings.png) | Отдельная нативная Settings scene с четырьмя вкладками. Развитие настроек T045–T048; backup manager/restore UI относится к последующим задачам. |
| Study / base-06, sheets-06/07 | [Вопрос](screenshots/release-question.png), [ответ](screenshots/release-answer.png), [итог](screenshots/release-summary.png) | Sheet с системными controls; нет полноразмерной композиции, цветных interval buttons/popovers и декоративного итога. Reveal/grades/skip/audio и сохранение работают; оформление T049/T050. |
| Editor / sheet-09 | [Редактор](screenshots/release-editor.png) | Явный Save/Cancel, обе preview стороны; основные поля/examples. UI вложений/тегов и типы карточек расширяются T036–T038; тест media здесь сервисный. |
| Export | [CSV](screenshots/release-export.png), [backup](screenshots/release-backup.png) | Нативный SavePanel, подтверждение успеха. APKG отключён; import/restore wizard ещё не подключён. CSV является содержимым, не backup прогресса. |

Виден смешанный язык: shell/menu/tab titles берут английскую системную
локаль, feature-тексты преимущественно русские даже при сохранённом Русский.
Это ограничение локализации до T044, не дефект сохранности. Визуальная
точность референсам и весь MVP этим документом не объявляются завершёнными.
