# Хранилище медиа T009

[Интеграции](INTEGRATIONS.md) · [Модель данных](DATA_MODEL.md)

Core-порт `MediaRepository` выдаётся `CollectionStore.media(generation:)`. Import публикует
immutable MediaAsset, но не меняет Note и не заменяет явный editor Save. Cancel редактора
не удаляет общий файл: удаление ссылки и будущий GC относятся к профильным задачам.

Первый профиль: PNG/JPEG/GIF/TIFF/HEIC/WebP через ImageIO (проверяются фактический UTI,
размеры и декодирование thumbnail), MP3/M4A/WAV через AudioToolbox (фактический container
и audio data). Расширение источника не определяет формат. Лимиты: 20 MiB/100 MiB,
изображение до 16384 px по стороне и 40 миллионов пикселей. Thumbnail PNG до 512 px
создаётся ImageIO на media actor, возвращается как Data и не входит в Media/backup.
Новых зависимостей и платных сервисов нет. ImageIO downsampling использует
[ограничение thumbnail](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize).

Протокол v1 в существующей `operation_journal` (`kind=media.v1`):

1. Под collection lease media actor ограниченно копирует выбранный regular file в
   `Staging/<UUID>/asset`, проверяет содержимое, SHA-256 и синхронизирует файл.
2. Writer фиксирует `prepare` с versioned manifest (hash, canonical extension, UTI,
   byteCount, assetID). После prepare отмена не прерывает короткую финальную фазу.
3. Atomic hard link публикует `Media/<sha256>.<ext>` без перезаписи; существующий файл
   проверяется по hash/размеру. Файл и directory синхронизируются до SQL-ссылки.
   Journal меняется на `publish`. Файловые действия не входят в SQL transaction.
4. Writer одной транзакцией INSERT-or-read дедуплицирует media_assets по SHA-256 и
   меняет journal на `commit`. Ни одна запись media_assets не предшествует publish.
5. Удаляется только staging этой операции; journal становится `cleanup` с completedAt.
   Ошибка cleanup после commit оставляет успешный результат и journal для startup.

Startup под эксклюзивным collection lease до выдачи контекста сверяет manifest и файлы:
prepare/publish без SQL asset откатываются до cleanup (опубликованный orphan сохраняется);
commit требует существующий файл с верным hash и SQL metadata, иначе open завершается
integrityFailure без выдачи повреждённого контекста. Unknown version/phase, unsafe paths
и несовпадающий manifest отклоняются без удаления. Неизвестные kinds не затрагиваются.
Повтор import после сбоя использует тот же immutable hash и единственный MediaAsset.
Файлы чужих pending operations, orphan Media и неизвестный staging никогда не удаляются.
Полный GC с проверкой undo/операций, Note attachment, playback, запись и UI — будущие задачи.

Все мутации journal/media_assets проходят один CollectionWriter; recovery при open
выполняется до создания writer при эксклюзивном владении. Close инвалидирует media port
перед writer/pool; старый порт не читает и не публикует в следующем generation.
Fault hooks доступны только тестам: после prepare, atomic publish, publish journal,
SQL commit и удаления staging. Это проверяет реальные file-backed SQLite/WAL и reopen,
включая сбой в промежутке publish → commit. Входные пути и содержимое не логируются.
