# Окружение разработки

[Архитектура](ARCHITECTURE.md) · [Проверки](QUALITY.md) · [Отчёт T001](task-reports/T001.json)

## Выбранные инструменты

Локальное измерение T001 от 18 октября 2026 года:

| Параметр | Фактическое значение |
|---|---|
| Developer directory | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | 27.1, build 27A9275 |
| Swift | Apple Swift 6.4, swiftlang-6.4.0.34.1, clang-2100.3.34.1 |
| macOS SDK | 27.0, `MacOSX27.0.sdk` внутри выбранного Xcode |
| Система выполнения | macOS 27.0.1, build 26A434 |
| Архитектура хоста и проверяемого бинарника | arm64 |
| Первичная настройка Xcode | `xcodebuild -checkFirstLaunchStatus` завершился с кодом 0 |

Полный Xcode уже выбран через `xcode-select -p`; менять системный выбор или устанавливать инструменты для T001 не потребовалось. Для воспроизведения с явным выбором, без изменения системной настройки:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
python3 scripts/check_environment.py
```

Скрипт требует Apple Silicon Mac с активным графическим сеансом. Он создаёт настоящий временный Xcode app target, выполняет clean build, проверяет effective build settings, arm64 и ad-hoc подпись, запускает бинарник `.app` и показывает пустое AppKit-окно. Через две секунды приложение проверяет `window.isVisible`, печатает `ANKI_NEW_WINDOW_VISIBLE` и завершается. Ошибка сборки, подписи, запуска или timeout даёт ненулевой exit code. Проект, бинарник и intermediates удаляются при выходе; коллекции, микрофон, сеть и пользовательские настройки приложение не использует. Структурированная сводка выводится в stdout; credentials и серийный номер устройства в неё не входят.

## Настройки приложения для T002

| Build setting | Значение |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `15.0` |
| `SWIFT_VERSION` | `6.0` — language mode, независимо от версии компилятора |
| `ARCHS` | `arm64` |
| `SDKROOT` | `macosx` выбранного Xcode |
| Временный bundle ID основного приложения | `local.anki-new.app` |
| Bundle ID одноразового smoke app | `local.anki-new.environment-smoke` |
| `DEVELOPMENT_TEAM` | пусто |
| `CODE_SIGN_IDENTITY` | `-` — Sign to Run Locally / ad-hoc |
| `CODE_SIGN_STYLE` | `Manual` для проверенного локального smoke target |

У smoke target нет provisioning capabilities, sandbox и hardened runtime; он проверяет компилятор и запуск окна. Sandbox основного приложения и file-selection entitlements остаются объёмом T002 и проверяются отдельно. Bundle ID временные; постоянный ID и обновление установленной `.app` проверяются к T096.

Вход в Apple Account, сертификат релиза, Developer ID, notarization и платная программа не использовались. `codesign --verify --deep --strict` успешно проверил собранную `.app`; `codesign -dvv` подтвердил `Signature=adhoc`. Это проверка локального запуска на данном Mac.

## Тестовые системы и команды

На текущем Mac скрипт T001 реально выполнил clean build и запуск окна. `vtool -show-build` подтвердил `platform MACOS`, `minos 15.0`, SDK 27.0. Значение minos не доказывает запуск на macOS 15: доступный Mac работает на 27.0.1. Другой установленной macOS и проверенного отдельного Mac с 15.0 в рамках T001 нет; переустановка ОС и виртуальная машина не выполнялись.

После T002 на текущей системе запускать из корня репозитория:

```sh
xcodebuild test -project AnkiNew.xcodeproj -scheme AnkiNew \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/local \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
swift test --package-path Packages/CardsKit
```

T002 зарегистрировала проект, схему и package path в `.github/automation.json`; состав targets и текущий запуск описаны в [каркасе приложения](APP_SCAFFOLD.md). Фактические результаты хранятся в отчётах задач. Проверка T001 не заменяет тесты основного приложения.

Для минимальной системы выполнять те же команды на отдельном Apple Silicon Mac с macOS 15 и совместимым полным Xcode (Swift 6.1+ по архитектурному контракту). Записывать фактические `sw_vers`, `xcodebuild -version`, SDK и результат каждой проверки. Нельзя выбирать старую macOS через `-destination` на новом хосте и считать её проверенной. Стандартный public runner `macos-15` даёт дополнительную проверку CI, но его фактические toolchain/OS и архитектуру нужно учитывать; он не заменяет локальные проверки разрешений и запуска на Mac владельца.

Новых пакетов, API, подписок, платной подписи или uploads в CI для T001 не добавлено. Дизайн-референсы для этой инфраструктурной задачи не требуются.
