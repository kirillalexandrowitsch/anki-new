# Наблюдаемые запросы T010

[Архитектура](ARCHITECTURE.md) · [Данные](DATA_MODEL.md)

`CollectionStore.queries(generation:)` выдаёт Foundation-only Core-порт `CollectionQueryService`.
Он возвращает library/decks/Today snapshots одноразово или через `QueryObservation` (AsyncSequence).
Снимок содержит generation; старый сервис после close/reopen непригоден. Наблюдение нужно
удерживать на время экрана и вызывать cancel при закрытии; отмена Task, освобождение последнего
итератора/наблюдения и закрытие коллекции также освобождают GRDB observation. После close даже
буферизованный snapshot старого generation не выдаётся. Буфер хранит только последний снимок.

Библиотека — строки Card, общие поля Note, направление variantKey/templateID, deck и schedule,
без SQL/GRDB в Features. Count Card и DISTINCT Note различаются. Страница по умолчанию 100,
допустимо 1…100, offset неотрицательный. Это нумеруемые страницы как sheet-20: сортировка имеет
ID tie-breaker; изменение состава может сдвигать границы страниц. Между запросами не обещается
замороженный снимок всей коллекции. Count и строки внутри одного snapshot согласованы.
Сортировки — изменение/слово в обе стороны, новые/изученные первыми; все SQL-фрагменты whitelist.
Фильтры — строка поиска, колода (точная или с активными потомками), тип Note, один тег,
phase и suspended. Удалённые Card/Note/Deck и suppressed/orphaned варианты исключены.
При фильтре по тегу исключён удалённый тег. Отсутствующее расписание считается new.

Поиск — AND из буквальных префиксов слов, unicode61 с case/diacritic folding, front/back/examples
Note; никакие введённые SQL/FTS операторы не исполняются. Пустая строка отключает поиск,
строка из пунктуации даёт пустой результат. Deck search — буквальная подстрока имени с escaped
LIKE. Максимальная длина поисковой строки 512 символов. Advanced AST, relevance ranking и
глобальный UI поиска относятся к последующим задачам. Данные не логируются.

FTS v2 использует обычную FTS5-таблицу `notes_fts` с rowid Note.
Поддерживаемый plain envelope fieldsJSON v1: front/back — строки верхнего уровня;
examples — массив объектов en/ru. Строки приводятся tokenizer к поисковым токенам; исходное
содержимое сохраняется. SQL projection общая для backfill и триггеров. INSERT/UPDATE/soft delete/
restore/physical DELETE поддерживают индекс в той же транзакции; migration backfill индексирует
существующие записи. Новые версии rich content должны расширять projection новой миграцией.
SaveNote реализуется T014; здесь интеграционная проверка сохраняет синтетическую Note через
существующий CollectionWriter и проверяет commit/rollback, обновление списка и FTS.
Перед v1→v2 автоматически сохраняется проверенная pre-migration SQLite-копия; схема v1 неизменна.
Откат кода требует совместимой копии, автоматической down migration нет.

Deck/Today используют общий набор карточек и SQL-агрегаты, без запросов на каждую строку.
Счётчики total/new/learning/review, suspended, buried и due — Card; notes — DISTINCT Note.
Due — active, unsuspended, unburied, non-new с dueAt <= asOf. New availability отделена от total new.
Это сырая доступность, без квот и без расчёта «изучено» по произвольному порогу. Today принимает
явное asOf; его нужно обновлять таймером/при активации, observation реагирует на БД, а не часы.
Полная учебная очередь/лимиты и UI Today — отдельные задачи. Deck counts относятся к собственной
колоде; фильтр scope включает потомков при явном флаге. Today выдаёт общие counters и страницу
колод, resume/session и слово дня здесь не добавляются. nameSearch ограничивает только страницу
колод, общие counters относятся к CardQueryFilter.

Новых библиотек, платных сервисов, CI uploads или личных данных нет. Исходные sheet-02/sheet-20
прочитаны и не меняются. Проверки — `CollectionQueryTests` и `CollectionDatabaseTests` в пакете.
