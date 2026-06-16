# TODO — Mihomo Subscription Manager

## v0.2-minimal (готов к merge в master) — 82d936c

### Что вошло
- **`tun.exclude-package: [526 RU пакетов]`** — legiz-список (Сбер, ВК, Авито, Яндекс, Озон, Wildberries, банки, операторы и т.д.). На Android — нативно (эквивалент системной галки «Запретить выбранные приложения»). На десктопе — игнорируется клиентом, fallback на `RULE-SET,ru_apps,DIRECT` (process-name).
- **`default-nameserver: [8.8.8.8, 1.1.1.1, 9.9.9.9]`** — Quad9 в конце, как запасной DNS.
- **`custom.yaml: tun-exclude-packages: [...]`** — per-user override (если юзер хочет свой список).

### Что НЕ вошло (уже было в master, не дублировал)
- AI-правило (`🤖 AI (Нейронки)`) — одиночное, дубля нет.
- Google-селектор (`🔎 Google`) — уже есть в `fd7d3b7`.
- Roblox убран, Steam DIRECT первым, Discord/YouTube с DIRECT — всё из твоих коммитов.

### Что НЕ вошло (dev-эксперименты, не доказано)
- `tun.exclude-package` (там тоже есть, но в dev — другие DNS, fake-ip→redir-host, lgbm и т.д.)
- `tun.smart` / `uselightgbm` — нет в mihomo for Android / FlClash / Clash Verge / NekoBox. PR #2711 open.
- Telegram-процесс-нейм (`PROCESS-NAME-REGEX,(?i).*telegram.*`) — не доказано, что лечит redmi/mido.
- DNS через PROXY (`respect-rules: true`, `nameserver-policy` для archlinux/omarchy) — не доказано.
- `route-exclude-address: 198.18.0.0/15` — убирать не нужно (master уже в порядке).

## План тестирования v0.2-minimal

1. Сделать `git pull` на сервере (или смерджить ветку).
2. Запустить `node src/build.js` — посмотреть в логе `[info] loaded 526 RU package(s)`.
3. Открыть сгенерированный конфиг, убедиться что есть `tun.exclude-package: [526 ...]` и `default-nameserver: [..., 9.9.9.9]`.
4. Раздать юзерам (1-2 человека), посмотреть:
   - RU-приложения (Сбер, ВК, Авито) — не ругаются на VPN?
   - Все ли сервисы работают как раньше (без регрессий)?
5. Если ок — merge в master, остальным юзерам.

## Открытые вопросы (после теста)

- Влияет ли 526 пакетов в exclude-package на производительность TUN на слабых Android (redmi 15)?
- Quad9 из РФ работает нормально или тоже блокируется DPI?
- Если у юзера 526 пакетов не помещаются в один exclude (Android-лимит) — что делать? (legiz-источник можно резать пополам).

## Связанные ветки
- `dev` — эксперименты с DNS / fake-ip / lgbm. Не для прода.
- `v0.2-minimal` ← **эта ветка**, готова к merge.
- `master` ← то, на чём работают юзеры сейчас.
