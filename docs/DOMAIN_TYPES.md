# Доменные типы и учебное время

[Архитектура](ARCHITECTURE.md) · [Модель данных](DATA_MODEL.md) · [Повторение](REVIEW_ENGINE.md)

T005 задаёт Foundation-only значения в `Packages/CardsKit/Sources/CardsCore/Models/` и `Study/`. Они не импортируют UI, GRDB или FSRS. `Deck`, `Note`, `Card` — неизменяемые Sendable DTO с типизированными IDs и revision, не SQL records и не изменяемые editor drafts. Начальный Note содержит текст по стабильным field IDs; rich content, examples/media и остальные предметные свойства вводятся соответствующими задачами. Эти Codable snapshots не объявляются форматом backup или SQLite-схемой.

## Идентичность и имена

`EntityID<Tag>` кодирует UUID одной строкой; NoteID/CardID/DeckID и остальные aliases несовместимы на уровне компилятора. Строковый ввод проверяется. `Revision` — неотрицательный Int64, начальное значение 0, `advanced()` проверяет переполнение. Декодирование сохраняет эти ограничения.

`EntityName` отдельно хранит displayValue (trim внешних Unicode whitespace/newlines, NFC) и normalizedValue (locale-independent case folding с фиксированной POSIX locale, затем NFC). Диакритика, пунктуация и внутренние пробелы сохраняются. Поэтому `Café` и `CAFÉ`, `Straße` и `STRASSE` совпадают; `café` и `cafe` различаются. Codable хранит только displayValue и восстанавливает нормализованный ключ. Пустое имя даёт `ValidationError.emptyName`, совпадение — `.duplicateName(normalized:)`.

`validateUniqueness(among:)` получает только активных соседей колоды или активные теги коллекции; при переименовании текущий ID исключает вызывающий сервис. Проверка в памяти не заменяет будущий UNIQUE constraint и транзакцию. Иерархию, generation и сохранение реализуют последующие сценарии.

`Grade` имеет raw values 1–4 (again/hard/good/easy), `SchedulePhase` — new/learning/review/relearning. Suspended, buriedUntil, generationState и deletedAt — независимые ограничения Card; они не становятся оценкой или фазой scheduler.

## Единицы времени

| Тип | Значение |
|---|---|
| `Date` / `Clock.now()` | Абсолютный момент; timezone применяется только при календарном расчёте |
| `EpochMilliseconds` | Int64 UTC epoch milliseconds на границе хранения; явные `init(date:)` и `.date` |
| `DurationMilliseconds` | Неотрицательное прошедшее время; сложение проверяет overflow |
| `SchedulerIntervalDays` | Неотрицательные целые дни долгосрочного scheduler; не календарные сутки коллекции |
| `StudyDayKey` | Проверенная Gregorian дата YYYY-MM-DD, без времени и UTC offset |

Между timestamp, duration и scheduler interval нет неявных преобразований или общих арифметических операторов. `init(date:)` округляет к ближайшей миллисекунде (равноудалённые — от нуля), отбрасывает nonfinite и значения за диапазоном Int64. Date использует floating point: крайние Int64 даты не гарантируют точность миллисекунды; исходный integer сохраняется без преобразования. Wall clock не измеряет активную длительность: для неё нужен monotonic источник вроде Swift.ContinuousClock; учёт foreground/pause относится к будущим задачам.

## Учебный день

`StudyDayCalculator(timeZoneID:rollover:)` явно получает timezone коллекции и начало дня (по умолчанию 04:00). Системный часовой пояс/Calendar.current не читаются. Вход — Date либо внедрённый Clock; выход — StudyDay с key, timezoneID и полуоткрытым `[start, end)`. End также служит ближайшей границей для burial/квот. Событие хранит собственные key/timezoneID, изменение настроек не пересчитывает историю.

Расчёт сравнивает момент с календарной границей текущей локальной даты. До неё используется предыдущая существующая локальная дата. Следующая дата получается через Calendar, а не прибавлением 86400 секунд: тесты покрывают дни в 23/25 часов и переходы Lord Howe на 30 минут. Полностью пропущенная гражданская дата (Apia, 2011-12-30) не создаёт фиктивный учебный день.

Для пользовательского rollover в DST gap применяется `.nextTime`: отсутствующее 02:30 становится первым существующим временем 03:00. Для DST fold применяется `.first`: повторное 01:30 не открывает день второй раз, и ключ не откатывается во время повторённого часа. Отдельно проверен пропуск полуночи в São Paulo: следующая нормальная полночь не теряется. Поддерживаются hour 0–23, minute 0–59. Неизвестный timezone, неверная дата/rollover, nonfinite либо выход за UTC годы 1–9999 возвращают типизированную ошибку. Правила зависят от системной базы timezone; тестовые векторы фиксируют известные переходы.

Проверка: `swift test --package-path Packages/CardsKit`; `StudyDayTests` содержит независимые UTC fixtures для timezone/04:00/DST, `DomainModelsTests` — Unicode, совпадения, validation/overflow, Codable и преобразования единиц. App target и минимальная macOS 15 дополнительно проверяются штатным CI.
