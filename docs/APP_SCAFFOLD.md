# Каркас приложения T002

[Архитектура](ARCHITECTURE.md) · [Окружение](ENVIRONMENT.md) · [Бюджет](BUDGET.md)

Открыть `AnkiNew.xcodeproj` и выбрать shared scheme `AnkiNew`. Основной target — `AnkiNew`, тесты приложения — `AnkiNewTests` и `AnkiNewUITests`. Схема запускает оба тестовых target; профилирование и архивирование используют Release. В `.github/automation.json` зарегистрированы проект, схема и единственный локальный пакет `Packages/CardsKit`. CI выполняет `xcodebuild test` и отдельно `swift test` пакета.

```sh
xcodebuild clean test -project AnkiNew.xcodeproj -scheme AnkiNew \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/local \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
swift test --package-path Packages/CardsKit
open build/local/Build/Products/Debug/AnkiNew.app
```

В проекте зафиксированы macOS 15.0, arm64 и Swift 6 language mode. Пакет требует Swift tools 6.1. Debug и Release используют локальную ad-hoc подпись, пустой development team и App Sandbox. Release включает hardened runtime; тестовые runners используют обычный режим без hardened runtime для загрузки ad-hoc тестовых bundles. При тестировании Xcode также может отключать runtime основного app с диагностикой в build log. Apple Account и provisioning profile не нужны. `App/AnkiNew.entitlements` разрешает чтение/запись только выбранных пользователем файлов и app-scope bookmarks для будущих файловых сценариев. Сеть и микрофон не разрешены. File panels, сохранение bookmarks и реальные import/export будут реализованы и проверены в своих задачах; наличие entitlement не означает готовый файловый сценарий.

Пакет экспортирует четыре продукта. Граф зависимостей: `CardsInfrastructure → CardsCore`, `CardsFeatures → CardsCore + CardsDesignSystem`. Core импортирует только Foundation. DesignSystem не зависит от домена; Features не импортирует инфраструктуру и не выполняет SQL. App связывает продукты в `CompositionRoot`, передавая реализацию Clock через протокол. Корень принадлежит сцене App; у каждого окна отдельная модель навигации. Глобального singleton и демо-коллекции нет. Зависимости закреплены T003, доменные типы реализованы T005, SQLite — T006. T007 подключает один CollectionCoordinator на App и открывает пустую коллекцию из sandbox Application Support; все окна используют один контекст при независимой навигации. Ошибки открытия видны с действием повторить; файловый выбор/переключение коллекций остаются последующими задачами.

В боковой панели пять входов: Сегодня, Колоды, Статистика, Библиотека, Настройки. Первые четыре переключают detail в `NavigationSplitView`. Последний открывает нативную сцену `Settings`, доступную также через меню приложения и Command-comma. В ней четыре вкладки: Основные, Повторение, Карточки, Данные. Экраны показывают заглушки будущей функциональности без вымышленных счётчиков, записей и активных неподключённых настроек. UI-тест проверяет запуск, все переходы и вкладки. Package tests проверяют подстановку времени и независимость навигации окон; app test проверяет composition root.

Строки Features находятся в String Catalog с русской и английской локализацией; имя приложения — в `App/Resources/InfoPlist.xcstrings`. Системные шрифты и SF Symbols не требуют дополнительных файлов. Пять исходных base PNG просмотрены как ориентир структуры окна; ни один дизайн-PNG не входит в resources/build phases. При приёмке T002 полная дизайн-система и полноценные экраны оставались последующими задачами; дизайн-система реализована в T004.

Локальный Git author сохранён из существующей настройки пользователя, credentials не менялись. Build outputs, DerivedData, `.build`, `.swiftpm`, `.xcresult`, `.local-data` и форматы коллекций исключены из Git. Проверки не используют личную коллекцию. Сторонних зависимостей, платных сервисов, CI artifact/cache uploads нет.


T004 разделяет bundle IDs: Debug — `local.anki-new.app.debug`, Release — прежний `local.anki-new.app`. Это изолирует XCUITest и sandbox Debug от одновременно запущенной Release-сборки. Оба app сохраняют ad-hoc подпись и пустой development team. Debug также содержит отдельную галерею компонентов через меню Окно; сцена не открывается/не восстанавливается автоматически и исключена из Release. Токены и API — в [дизайн-системе](DESIGN_SYSTEM.md).

T007: shared scheme TestAction передаёт Debug host `-CollectionTestID` с фиксированным тестовым UUID; UI tests задают собственный UUID на каждый запуск. Debug разрешает только UUID и выводит путь из sandbox temporaryDirectory. Поэтому тесты автозапуска не открывают пользовательский registry в Application Support. Release этого режима не содержит. CollectionCoordinatorTests используют внедрённый Core port, Infrastructure tests — отдельные временные папки и процессы. Lifecycle/формат описаны в [DATA_MODEL.md](DATA_MODEL.md).
