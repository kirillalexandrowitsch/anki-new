# Резервная копия и восстановление T011

[Интеграции](INTEGRATIONS.md) · [Архитектура](ARCHITECTURE.md)

`CollectionStore.createBackup(to:generation:)` создаёт `.cardsbackup` в выбранном локальном месте,
`restoreBackup(from:generation:)` заменяет открытую коллекцию и возвращает новый CollectionContext.
Это Infrastructure API; панели файлов, подтверждение замены, автокопии и retention добавляются
профильными UI-задачами. Успех restore означает новый generation; старые repositories и observations
инвалидируются. Ошибка до финального переключения оставляет действующий context доступным.
Ошибка во время переключения требует повторного `open()`, который сначала выполняет recovery.

## Формат v1

ZIPFoundation 0.9.20 (уже принятая бесплатная зависимость), обычный ZIP без шифрования:
`manifest.json`, `collection.json`, `collection.sqlite`, `Media/<sha256>.<ext>`.
Manifest содержит formatVersion, databaseVersion, collectionID, createdAt и SHA-256/размер каждого
payload-файла. Это проверка целостности, не подпись доверенного издателя. Registry, WAL/SHM,
locks, Staging, Trash, thumbnails, cache и предыдущие backups в архив не входят.
Все строки SQLite, включая tombstones, history, parameter sets, command/operation journal,
сохраняются; все зарегистрированные immutable media копируются, включая не прикреплённые.
Неучтённые orphan-файлы без строки media_assets не входят в логическую коллекцию.

Стабильный `root/.operations.lock` удерживается от open до close и находится вне заменяемого
контейнера. Это operation/lifecycle lease для текущей единственной коллекции, в том числе между
процессами. Snapshot и список media выполняются без suspension на общем writer actor:
SQLite Backup API включает committed WAL; staged DB переводится в DELETE-journal mode, проверка и копирование immutable media завершаются
до освобождения writer. Записи ждут окончания snapshot. Архивирование идёт на store actor.
Close и вторая длительная операция во время backup отвергаются как operationInProgress.
Отмена до переключения безопасна; после начала rename короткая commit-фаза не отменяется.

Временный ZIP создаётся рядом с целевым файлом, полностью читается и проверяется, fsync выполняется
до атомарного hard-link publish без перезаписи существующего файла. Destination должен быть вне
root коллекции. Старые копии не удаляются. Файловый доступ — security scope на время операции.

## Валидация и swap

Распаковка идёт потоково только в новую приватную staging-папку. Запрещены directories/symlinks,
дубликаты, абсолютные/не канонические пути и посторонние entries. Ограничения v1: 100 003 entries,
2 GiB суммарно, manifest до 32 MiB, отношение распаковки до 1000; учитываются фактические байты,
CRC и SHA-256. Media проверяются по строкам SQLite и профилю T009; SQLite — read-only preflight,
integrity_check, foreign_key_check, schema/identity. Принимается текущая database schema v2;
будущая совместимость со старыми версиями потребует явной политики migration в staging.

После полной проверки staging содержит готовый контейнер. Закрываются media/writer/observations.
В `root/restore-journal.json` атомарно и с fsync сохраняются version, operation UUID, прежний registry
и новый ID. Пути вычисляются из UUID, произвольных путей в журнале нет. Старый контейнер переносится в `root/.restore-<UUID>/rollback`, staging — в Collections/newID,
registry атомарно обновляется; только затем журнал получает committed=true. Это точка commit.
Синхронизация каталогов упорядочивает каждый rename перед следующим шагом.

Startup под тем же lease обрабатывает журнал **до чтения registry**. Prepared всегда возвращает
старый контейнер и registry, даже если новый уже установлен; committed сохраняет новый.
Rollback сначала копируется в recovery-кандидат, затем атомарно возвращается на старый путь:
исходный rollback остаётся до удаления журнала, поэтому повторное падение recovery безопасно.
После удаления и fsync журнала убирается временная папка. Повторный open идемпотентен.
Ошибка до durable удаления журнала оставляет его для повторной попытки. Отказ последующей
уборки оставляет только временную папку; исходные данные не удаляются до commit. Ни исходники Git, ни backup restore не понижают SQLite schema автоматически.
