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

---

## Сделано (коммиты на master)

- **`0d3e4d1` — убрать Steam и Google из генератора** (src/build.js).
  Удалены proxy-groups `🎮 Steam`, `🔎 Google`; rule-providers `steam`, `geosite-google`, `google-geoip`; соответствующие rules. Вернуть — `git revert 0d3e4d1`.
- **`2a02d7b` — fallback timeout 5000ms → 2500ms.** Юзеры жаловались на долгое переключение при лаге.
- **`4bf1d4f` — proxy-provider health-check interval 600s → 180s.** Быстрее детектится мёртвый сервер.

## Будущие оптимизации стабильности (не сделано, требует обсуждения)

### Telegram-флап (онлайн/оффлайн/онлайн)
- Симптом: телега грузит несколько секунд, потом несколько секунд оффлайн, потом снова грузит.
- Группа `➤ Telegram` завязана на `🌍 Иностранные серверы` (= fallback-группа). При лаге сервера fallback переключается → телега рвёт соединение.
- Варианты:
  1. Посадить `➤ Telegram` на `♻️ Резерв (RU -> EU)` (fallback RU→EU) — больше живых альтернатив.
  2. Посадить на статику (один конкретный сервер) — нет переключений, но нет отказоустойчивости.
  3. Оставить как есть, но понимать что это следствие fallback-переключений, а не баг телеги.

### fake-ip-filter для Telegram
- Сейчас `fake-ip-filter: ['+.telegram.org', '+.t.me']` заставляет телегу резолвиться реальным DNS, IP кэшируется на клиенте. При переключении сети / смене сервера кэш устаревает → соединение рвётся на несколько секунд.
- Вариант: убрать `+.telegram.org` и `+.t.me` из fake-ip-filter → пусть mihomo сам управляет IP телеги через fake-ip. Минус — возможные артефакты с push-уведомлениями на iOS.

### DoH через 8.8.8.8 / cloudflare-dns.com
- Сейчас `nameserver: ['https://8.8.8.8/dns-query', 'https://cloudflare-dns.com/dns-query']`.
- DoH из РФ лагает и периодически режется DPI → медленный резолв → «телега грузит несколько секунд».
- Вариант:
  - **A.** Plain DNS: `nameserver: ['1.1.1.1', '8.8.8.8']` + `default-nameserver: ['1.1.1.1', '8.8.8.8']` (bootstrap).
  - **B.** DoT: `nameserver: ['tls://8.8.8.8:853', 'tls://1.1.1.1:853']`.
  - **C.** Резолв только DNS-серверами Amnezia (которые зашиты в ключах, `172.x.x.254`). Нельзя ставить в `nameserver` напрямую — эти адреса недостижимы ДО поднятия туннеля; но можно через `nameserver-policy` после поднятия. Сложно, не для минимальной правки.

### `tcp-concurrent: true` на мобильных
- Опция открывает параллельные TCP-соединения к одному хосту. На мобильных сетях при переключении сот / Wi-Fi↔LTE Established-сессии могут рваться.
- Вариант: отключить (убрать строку) как эксперимент — измерить, стало ли стабильнее.

### Объединить WhatsApp + Instagram + Facebook → один селектор «Meta»
- Сейчас 3 отдельных proxy-group (`📞 WhatsApp`, `📸 Instagram & Threads`, `👥 Facebook`) и 4 rule-provider (`geosite-instagram`, `geosite-facebook`, `geosite-meta`, `whatsapp-domains`, `facebook-ips`).
- Предложение: один селектор `👥 Meta`, правило `OR,((RULE-SET,geosite-meta),(RULE-SET,whatsapp-domains),(RULE-SET,facebook-ips),(IP-ASN,32934)),👥 Meta`.
- Минус: юзер теряет гранулярность (нельзя пустить WA через один сервер, Instagram через другой). Если гранулярность не нужна — упрощает конфиг и убирает дублирующие правила.

### `health-check url: gstatic.com/generate_204`
- Нормально в целом, но `gstatic.com` ресолвится через Google — может лагать в РФ. Альтернатива — `https://www.google.com/generate_204` или `http://cp.cloudflare.com/generate_204`. Не критично.

### Падение при переключении между сетями (Wi-Fi ↔ мобильная)
- Общая проблема: при смене сети TUN-интерфейс остаётся, но все Established-соединения рвутся. Это не баг конфига, это свойство TCP/QUIC.
- Mihomo при `auto-detect-interface: true` должен подхватить новый интерфейс, но fallback-группы при этом могут уйти в таймаут на целые `timeout` ms (сейчас 2500ms — уже лучше, было 5000ms).
- Снижение fallback timeout уже частично лечит. Дальнейшие шаги:
  - Уменьшить `interval` у fallback-групп до 60-120s (быстрее переоценка доступности).
  - Добавить ` tolerance: 500 ` в fallback? (опция mihomo — wait ms перед переключением, сглаживает единичные лаги).

### `unified-delay: true` + `lazy: true`
- Уже включено — правильная связка. Не трогать.
