# Автономная доставка задачи

[Правила чатов](AI_WORKFLOW.md) · [Состояние](PROJECT_STATUS.md) · [Бюджет](BUDGET.md)

Репозиторий публичный: [kirillalexandrowitsch/anki-new](https://github.com/kirillalexandrowitsch/anki-new). Пользователь подтвердил, что скачанные копии не отзываются последующим закрытием.

Команда нового чата: «Выполни следующую доступную задачу по AGENTS.md и доведи её через dev → stage → main». Codex работает через существующую подписку локально; Actions выполняют только CI, без OpenAI API и дополнительных AI-платежей.

## Исполняемые команды

```sh
python3 scripts/start_task.py next
# Прочитать карточку, реализовать, выполнить проверки и заполнить отчёт.
python3 scripts/tasks.py finish Txxx
python3 scripts/ci.py quality
# Commit конкретных файлов с ID задачи.
python3 scripts/deliver.py --task Txxx
```

Для настройки процесса используется maintenance/<slug> и docs/automation-reports/<slug>.json; доставка — `python3 scripts/deliver.py --maintenance <slug>`. Все PR проходят те же обязательные CI jobs.

## Защита

На dev/stage/main применяется `.github/branch-protection.json`: обязательные quality/macos, защита также для администратора, запрет force push/удаления и незакрытых обсуждений. PR review другого человека не требуется: проект ведёт один владелец, а критерии и автоматические проверки обязательны.

Агент делает merge существующим gh login только после SUCCESS обоих checks. У workflow token contents:read, он не делает merge и не получает Apple/AI credentials. GitHub разрешает только выбранные GitHub-owned actions; checkout закреплён полным SHA. Branch promotion использует обычные merge-коммиты, временные ветки не удаляются автоматически.

Порядок: task/Txxx→dev; зелёный post-merge run; dev→stage; зелёный post-merge run; stage→main; зелёный post-merge run. Deliver может безопасно продолжить уже выполненные стадии для того же candidate SHA. Изменившиеся head/base или красный CI требуют исправления/свежих проверок; обход защиты не поддерживается.

## Текущий этап CI

На этапе документации оба jobs проверяют существующий проектный процесс на Linux и macOS. App build включается автоматически как обязательный путь после появления Xcode project; project/scheme/packages должны быть явно зарегистрированы в automation.json. Незарегистрированные новые packages и завершённая T002 без app config приводят к ошибке. Пока приложения нет, CI не объявляет его собранным или протестированным.

Для экономии artifact/cache uploads не используются; runners только стандартные ubuntu-24.04 и macos-15. При private оба jobs не запускаются, deliver отказывает; требование нулевых дополнительных платежей сохраняется.

При реальной недоступности GitHub, системном запросе или лимите Codex сохраняется конкретный незавершённый этап. Зелёный CI — необходимое условие доставки, а не утверждение об отсутствии всех возможных ошибок.
