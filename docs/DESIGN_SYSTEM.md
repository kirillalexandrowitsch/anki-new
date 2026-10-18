# Дизайн-система T004

[Архитектура](ARCHITECTURE.md) · [Правила и токены](../design-references/DESIGN.md) · [Отчёт](task-reports/T004.json)

`Packages/CardsKit/Sources/CardsDesignSystem` содержит только SwiftUI/AppKit-компоненты, ресурсы локализации и локальное UI-состояние. Модуль не зависит от Core, Features, Infrastructure и внешних пакетов. Никаких моделей коллекции, SQL, файлов коллекции или глобальных сервисов ему не требуется.

## Токены

`CardsColor` задаёт семантические динамические NSColor: window, surface, secondarySurface, text, secondaryText, separator, accent, accentFill, success, warning, danger. Они разрешаются для light/dark в SwiftUI, previews и ImageRenderer без отдельного asset compiler для CLI SwiftPM. Системный повышенный контраст усиливает границы контролов; дополнительный `cardsIncreasedContrast=true` позволяет проверить это в галерее, не изменяя системные настройки.

Основа — DESIGN.md. Светлый success уточнён до `#20865B`: предложенный `#20875B` даёт только 4,489:1 на белом. Светлый danger уточнён до `#B32939`, чтобы текст опасной кнопки оставался читаемым на тонированной поверхности при hover/pressed. Accent для ссылок в dark — `#8792FF`, а accentFill для белой надписи в обеих темах — `#4F5FF5`. Проверяются реальные разрешённые цвета, а не независимая копия таблицы. Нельзя использовать светлый dark-accent как заливку под белую надпись.

`CardsTextStyle`: windowTitle 28 semibold, sectionTitle 20 semibold, body 15, caption 13, studyWord 40 semibold, translation 22 pt. Шрифт системный. `cardsText()` использует ScaledMetric и `cardsTextScale` (standard / enlarged 135%); дополнительно поддерживает доступное на системе масштабирование текста. Для чисел вызывающий код добавляет `monospacedDigit()`. Текст переносится; высоты кнопок/полей заданы только снизу, не фиксированы.

`CardsSpacing`: 4, 8, 12, 16, 24, 32 pt. `CardsRadius`: control 8, panel 12, card 16. У обычных контролов минимум 32 pt; размеры основных учебных действий задаются их будущими экранами. Панель имеет отступ 24 pt и тонкую границу без декоративной тени.

## Компоненты

| API | Поведение и граница ответственности |
|---|---|
| `CardsButtonStyle(.primary/.secondary/.destructive)` | Настоящий SwiftUI Button, системная активация клавиатурой и доступность. Hover меняет заливку, pressed также сдвигает на 1 pt. Focus — отдельная внешняя рамка. Disabled — пунктир плюс `nosign`, ввод блокирует стандартный `.disabled`. Роль, shortcut, default и подтверждение опасной операции задаёт вызывающий экран. |
| `CardsField(title, text:, prompt:, help:, error:)` | Нативный однострочный TextField с Binding. Постоянная подпись, отдельные help/error, error со значком и текстом, focus с внешней рамкой, disabled с пунктиром и поясняющим статусом. VoiceOver получает название, значение и ошибку. Валидация и запрет Save принадлежат экрану, значение при disabled сохраняется. |
| `CardsPanel(title?) { content }` | Поверхность и отступы; необязательный заголовок получает header trait. |
| `CardsBanner(kind, title:, message:)` | Информация/успех/предупреждение/ошибка различаются словами и формой SF Symbol. Текст сообщения не зависит от его цветовой заливки. Изменение текста объявляется через AccessibilityNotification без перехвата фокуса; таймера скрытия нет. |
| `CardsEmptyState(title, symbol:, message:) { action }` | Причина пустоты и необязательное действие, переданное экраном. Не создаёт фиктивных данных. |
| `CardsLoadingState(title, progress: nil)` | Нативный индикатор и название операции. Доля/процент только при переданном измеренном progress; запускающую кнопку и допустимую отмену контролирует экран. |

Переключатели, checkbox, segmented и pop-up остаются системными Toggle/Picker; в галерее есть живые примеры. Подсказки задаются `.help`. Для icon-only Button обязательно содержательное accessibilityLabel. У компонентов нет пользовательских анимаций или ожидания их завершения; системные индикаторы следуют настройкам macOS.

Строки общих состояний и галереи находятся в RU/EN String Catalog. Контент, передаваемый в публичный API как String, локализует вызывающий модуль. Образцы кириллицы, латиницы и IPA в типографике намеренно показываются вместе.

## Просмотр и проверка

В Xcode открыть `CardsGallery.swift`: Light, Dark, Large text / Light, Large text / Dark previews. В Debug-приложении меню **Окно → Дизайн-система** открывает отдельное окно. Оно не открывается автоматически и не восстанавливается при запуске; в Release этой сцены нет. Галерея поддерживает light/dark, 135% текст, повышенный контраст и четыре страницы: кнопки, поля/переключатели, сообщения/пустота/загрузка, типографика/цвета. Это образцы, а не рабочая коллекция. Фиксированные hover/pressed/focus образцы недоступны для нажатия; отдельная интерактивная панель проверяет настоящие действия.

```sh
swift test --package-path Packages/CardsKit
CARDS_DESIGN_SNAPSHOTS="$PWD/build/t004-snapshots" swift test --package-path Packages/CardsKit
xcodebuild test -project AnkiNew.xcodeproj -scheme AnkiNew \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/t004-app \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

DesignSystemTests проверяют контраст текста/поверхностей в обеих темах и различимость 30 стабильных button renders: 3 вида × 5 состояний × 2 темы. При переменной CARDS_DESIGN_SNAPSHOTS PNG сохраняются только локально в игнорируемой build-папке; дополнительные images галереи показывают normal/large и light/dark. Полнооконные pixel baselines не закрепляются, native TextField и spinner не считаются результатом ImageRenderer. XCUITest проверяет настоящие Button/shortcuts/disabled, ввод текста и Tab между полями, появление ошибки и переключение тем/масштаба; native controls дополнительно проверяются визуально через NSHostingView той же галереи. Снимки и личные данные в Git/CI artifacts не загружаются.

Фактические результаты и границы проверки записаны в отчёте T004. Полный аудит VoiceOver и доступности всех будущих экранов остаётся отдельными задачами. Новых зависимостей, внешних шрифтов, платных сервисов и платежей нет; 48 исходных PNG не изменяются.

Кнопка macOS не получает клавиатурный фокус от щелчка мышью. Полный Tab-путь и активация Пробелом следуют системной Keyboard Navigation; галерея не изменяет эту настройку владельца. Её интерактивные кнопки также имеют ⌘R / ⇧⌘R. Это стандартное поведение объяснено в [Apple Focus Cookbook](https://developer.apple.com/videos/play/wwdc2023/10162/); внешняя focus-рамка стиля читает системный isFocused, дополнительные focusable-обёртки к Button не добавляются.

Локальный XCUITest не смог создать полнооконный screenshot на втором мониторе. Поэтому test не делает полнооконных снимков: стабильные кнопки снимаются ImageRenderer, нативные поля/сообщения снимаются кэшем AppKit через NSHostingView той же галереи. Такие review images показывают неактивное окно и не используются как pixel baselines. Положение пользовательских окон и настройки дисплеев ради capture не изменяются.
