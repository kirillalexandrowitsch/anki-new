# Проверенные зависимости

[Архитектура](ARCHITECTURE.md) · [Бюджет](BUDGET.md) · [T003](tasks/T003.md)

Проверка T003 от 18 октября 2026 года. Runtime только локальный; обязательных
платных API, аккаунтов, trial, подписок или платежей у выбранных пакетов нет.
SPM получает исходники бесплатно с публичного GitHub. Каждый пакет — MIT,
разрешены личное и коммерческое использование, изменение и распространение;
нужно сохранить copyright и текст лицензии. Они включены целиком в
`CardsInfrastructure/Resources/ThirdPartyNotices.txt` и копируются в bundle.
Гарантий от авторов нет. Телеметрия/сетевой сервис приложению не добавлены.

## Pins и транзитивный состав

| Пакет | Версия / commit | Первичный источник и лицензия |
|---|---|---|
| GRDB.swift | **7.11.1**, `b83108d10f42680d78f23fe4d4d80fc88dab3212` | [manifest](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/Package.swift), [MIT](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/LICENSE) |
| swift-fsrs | revision **`4fbaf20184d62f82a9f44f343337c61a2c5483e9`** | [manifest](https://github.com/open-spaced-repetition/swift-fsrs/blob/4fbaf20184d62f82a9f44f343337c61a2c5483e9/Package.swift), [MIT](https://github.com/open-spaced-repetition/swift-fsrs/blob/4fbaf20184d62f82a9f44f343337c61a2c5483e9/LICENSE) |
| ZIPFoundation | **0.9.20**, `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | [Swift 5.9 manifest](https://github.com/weichsel/ZIPFoundation/blob/22787ffb59de99e5dc1fbfe80b19c97a904ad48d/Package%40swift-5.9.swift), [MIT](https://github.com/weichsel/ZIPFoundation/blob/22787ffb59de99e5dc1fbfe80b19c97a904ad48d/LICENSE) |

Все требования в [Package.swift](../Packages/CardsKit/Package.swift) — exact
или 40-символьная revision, без branch/main/latest и диапазонов.
[Package.resolved](../Packages/CardsKit/Package.resolved) фиксирует все три
revision. Xcode хранит отдельную копию lockfile в project workspace; при
обновлении зависимости обновлять оба lockfile и повторять проверки ниже.

Дополнительных удалённых runtime-зависимостей в разрешённом графе нет.
GRDB использует системную SQLite через GRDBSQLite; ZIPFoundation на macOS —
системный Compression, Foundation и Darwin. Не включены SQLCipher и
`SPI_BUILDER` (его docc plugin нужен только сборщику документации upstream).
FSRS не имеет зависимостей. Linux-вариант ZIPFoundation с CZLib не является
проверкой целевой macOS-платформы. Системные библиотеки поставляются Apple,
не загружаются как отдельный платный продукт.

## Совместимость и воспроизведение

Проект: macOS 15+, arm64, Swift 6 language mode, tools 6.1+.
GRDB использует language mode 6. FSRS (tools 5.10, strict concurrency complete)
и ZIPFoundation (tools 5.9, language mode 5) собираются как upstream-пакеты;
это не заявление о полной миграции их исходников в Swift 6. Наши вызывающие
модули и smoke-тесты компилируются в Swift 6 без `@preconcurrency` и без
ослабления проверок. Mutable Archive остаётся внутри одной фоновой задачи;
GRDB connection не покидает closure. FSRS хранит immutable configuration;
32 параллельных вызова одного scheduler сверяются с последовательным.

Запуск из корня:

```sh
swift package --package-path Packages/CardsKit resolve
swift test --package-path Packages/CardsKit
python3 scripts/ci.py macos
```

`ci.py macos` действительно запускает xcodebuild test и swift test на
стандартном macos-15; только оба SUCCESS позволяют доставку. Локально
проверено на macOS 27.0.1 arm64 / Xcode 27.1 / Swift 6.4. Runtime ровно
macOS 15.0 недоступен на этом Mac; проверка ветки macOS 15 выполняется
на hosted runner, точная версия и run записываются в отчёте T003.

- `DatabaseCompatibilityTests`: реальный временный file-backed DatabasePool,
  async write/read, WAL, FTS5 unicode61 и кириллический MATCH, rollback при
  исключении, 12 конкурентных write/read, integrity_check=ok, повторное
  открытие и поиск сохранённого текста. Не используется коллекция владельца.
- `ArchiveCompatibilityTests`: deflate ZIP с Unicode-путём и текстом,
  бинарными 256 значениями байта и пустым файлом; чтение каждой entry,
  сравнение CRC и байтов, распаковка на диск и повторное сравнение.
- `FSRS6CompatibilityTests`: независимый JSON oracle, 5 входных snapshots
  (new, learning, review, relearning, overdue), все 4 оценки — 20 результатов;
  сравниваются stability/difficulty с абсолютным допуском 1e-7, точные due,
  state, learning step, repetitions/lapses и остальные поля карточки.
  Preview равен next; параллельные вызовы детерминированы.

## FSRS-6: профиль и независимый oracle

`FSRS6Configuration` внутри Infrastructure явно передаёт 21 вес FSRS-6,
retention=0.9, maximum interval=36500 дней, fuzz=false, short term=true,
learning=[1m,10m], relearning=[10m]. Отдельно проверяется version==v6;
`FSRSParameters()` без весов оставлен upstream как FSRS-5 и запрещён для
продуктового расчёта. Полный доменный адаптер, валидация входных параметров и
политика учебного времени остаются T017; внешние типы не выходят в Core/UI.

[Fixture](../Packages/CardsKit/Tests/CardsInfrastructureTests/Fixtures/fsrs6-reference.json)
получена запуском **ts-fsrs 5.4.2**, независимой TypeScript-реализации,
[source revision bb71e35](https://github.com/open-spaced-repetition/ts-fsrs/tree/bb71e35a2f5af5a5ac6cce9ef7c41ad24855721d),
[MIT](https://github.com/open-spaced-repetition/ts-fsrs/blob/bb71e35a2f5af5a5ac6cce9ef7c41ad24855721d/LICENSE).
Это dev-only oracle: Node/npm не нужны ни приложению, ни обычному CI;
нет транзитивных npm runtime-зависимостей. Версия, source revision и npm
SHA-512 integrity сохранены в fixture и generator. Дата — фиксированная UTC,
не зависит от местного часового пояса. Выходы не скопированы из Swift.

Воспроизведение oracle (уже выполнено при T003):

```sh
npm install --prefix build/dependency-audit/reference --ignore-scripts --no-audit --no-fund --save-exact ts-fsrs@5.4.2
node scripts/generate_fsrs_fixture.cjs > build/dependency-audit/fsrs6-reference.json
cmp build/dependency-audit/fsrs6-reference.json Packages/CardsKit/Tests/CardsInfrastructureTests/Fixtures/fsrs6-reference.json
```

Для новой карточки 2025-01-01T12:00:00Z:

| Оценка | stability | difficulty | Следующий срок | Фаза |
|---|---:|---:|---|---|
| Again | 0.212 | 6.4133 | +1 минута | learning |
| Hard | 1.2931 | 5.11217071 | +6 минут | learning |
| Good | 2.3065 | 2.11810397 | +10 минут | learning |
| Easy | 8.2956 | 1 | +8 дней | review |

Первое сравнение с ts-fsrs 5.2.0 выявило 9 несовпадений для learning/relearning.
Причина установлена по upstream: 5.2.1 исправляет premature graduation,
5.3.0 — non-decreasing same-day Hard stability, 5.3.1 — skipping learning
steps ([changelog](https://github.com/open-spaced-repetition/ts-fsrs/blob/bb71e35a2f5af5a5ac6cce9ef7c41ad24855721d/packages/fsrs/CHANGELOG.md)).
Swift revision уже содержит эти изменения. С соответствующей 5.4.2 все
20 результатов проходят без изменения значений или расширения допуска.
Не заявляется совместимость с любой версией ts-fsrs или произвольным набором
весов/steps. При будущем расхождении сначала остановить интеграцию и
разобрать причину, не подменять oracle результатами Swift.

## Ресурсы и ограничения

GRDB копирует собственный PrivacyInfo.xcprivacy в resource bundle: tracking
false, collected data и accessed API types пусты. ZIPFoundation через manifest
Swift 5.9 копирует PrivacyInfo.xcprivacy: tracking false, collected data пусто,
FileTimestamp reason 0A2A.1. FSRS не имеет ресурсов/manifest и не использует
файловые required-reason API в проверенном алгоритме. Наличие manifests и
ThirdPartyNotices проверять в собранной .app, а не только в checkout.

ZIP smoke не реализует безопасный ArchiveService, лимиты распаковки,
защиту от path traversal, backup/restore и APKG — это последующие задачи.
GRDB smoke не создаёт схему коллекции или миграции. Проверка FSRS не завершает
продуктовый планировщик, Undo или учебные квоты. Проверены выбранный профиль и
фиксированные UTC-векторы; fuzz, DST, произвольные/повреждённые параметры и
альтернативные learning steps не принимаются этим отчётом.
