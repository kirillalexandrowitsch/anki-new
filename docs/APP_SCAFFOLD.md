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

Пакет экспортирует четыре продукта. Граф зависимостей: `CardsInfrastructure → CardsCore`, `CardsFeatures → CardsCore + CardsDesignSystem`. Core импортирует только Foundation. DesignSystem не зависит от домена; Features не импортирует инфраструктуру и не выполняет SQL. App связывает продукты в `CompositionRoot`, передавая реализацию Clock через протокол. Корень принадлежит сцене App; у каждого окна отдельная модель навигации. База данных, глобальный singleton, внешние пакеты и демо-коллекция пока отсутствуют. Начальный Clock используется для даты на экране Сегодня; правила учебного дня и остальные доменные типы остаются объёмом T005.

В боковой панели пять входов: Сегодня, Колоды, Статистика, Библиотека, Настройки. Первые четыре переключают detail в `NavigationSplitView`. Последний открывает нативную сцену `Settings`, доступную также через меню приложения и Command-comma. В ней четыре вкладки: Основные, Повторение, Карточки, Данные. Экраны показывают заглушки будущей функциональности без вымышленных счётчиков, записей и активных неподключённых настроек. UI-тест проверяет запуск, все переходы и вкладки. Package tests проверяют подстановку времени и независимость навигации окон; app test проверяет composition root.

Строки Features находятся в String Catalog с русской и английской локализацией; имя приложения — в `App/Resources/InfoPlist.xcstrings`. Системные шрифты и SF Symbols не требуют дополнительных файлов. Пять исходных base PNG просмотрены как ориентир структуры окна; ни один дизайн-PNG не входит в resources/build phases. Полная дизайн-система и полноценные экраны остаются последующими задачами.

Локальный Git author сохранён из существующей настройки пользователя, credentials не менялись. Build outputs, DerivedData, `.build`, `.swiftpm`, `.xcresult`, `.local-data` и форматы коллекций исключены из Git. Проверки не используют личную коллекцию. Сторонних зависимостей, платных сервисов, CI artifact/cache uploads нет.
