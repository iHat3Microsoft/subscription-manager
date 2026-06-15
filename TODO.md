# TODO — Mihomo Subscription Manager

## v0.2 (dev) — в работе

### Цель
Сделать mihomo-конфиг надёжнее и удобнее для типичных RU-юзеров:
- **Телеграм** на redmi 15 / mido (crDroid) подключается без socks5-прокси в самой телеге.
- **WhatsApp/Instagram** — сообщения и сторис грузятся стабильно.
- **RU-приложения** (Сбер, ВК, Авито) не ругаются на VPN.
- **pacman** на omarchy работает через mihomo (Arch + Cloudflare-зеркала).
- **DNS** не утекает в обход VPN, не залипает на замедленных CF-зеркалах.

### Что сделано (dev branch)

- [x] `src/test-config.builder.js` — генератор тестового конфига без `proxy-providers`.
- [x] Парсинг `ru-app-list.yaml` (legiz) → 526 уникальных пакетов в `data/ru-packages.txt` (локально, в гит не пушим).
- [x] DNS: `redir-host` (без fake-ip), `respect-rules: true`, `proxy-server-nameserver` через тег `#PROXY`, `nameserver-policy` для `+.omarchy.org`/`+.archlinux.org`/`+.github.com`/`+.githubusercontent.com`/`+.jsdelivr.net`/`raw.githubusercontent.com` → DNS через PROXY.
- [x] `tun.exclude-package: [526 пакетов]` — нативное Android-исключение (эквивалент системной галке «Запретить выбранные приложения»).
- [x] `RULE-SET,ru_apps,DIRECT` (legiz, уже в `master`) — запасной process-name fallback для десктопа и приложений не из exclude.
- [x] Правило Telegram: `PROCESS-NAME-REGEX,(?i).*telegram.*` поднят в одно правило с `telegram-ips/domains` (лечит redmi/mido, где домен не резолвится через `fake-ip`).
- [x] AI-правило: убран дубль (было два одинаковых правила).
- [x] `tun.route-exclude-address` — убран `198.18.0.0/15` (ломает fake-ip, при redir-host не нужен).
- [x] `proxy-groups`: `⚡️ Fastest` (url-test, основная автобалансировка), `♻️ Автовыбор` (fallback, запасной). **`📊 Smart` (type: smart) убран — не поддерживается в mihomo for Android / FlClash / Clash Verge / NekoBox.**

### Что тестируется (этап 1)

- [ ] **Telegram** на redmi 15 / mido (crDroid) — подключается без socks5 в самой телеге?
- [ ] **WhatsApp** — сообщения отправляются у всех юзеров?
- [ ] **Instagram сторис** — грузятся у юзеров, у которых раньше не грузились?
- [ ] **pacman** на omarchy — `sudo pacman -Syy` отрабатывает?
- [ ] **RU-приложения** (Сбер, ВК, Авито) — не ругаются на VPN, push-уведомления приходят?
- [ ] **Скорость** — стало лучше, чем раньше (т.к. `url-test` сам выбирает лучший сервер)?

### Что не сделано (этап 2, после зелёного теста)

- [ ] Перенести изменения в `src/build.js` (отдельный коммит в dev).
- [ ] Поддержка `tun.exclude-package` для кастомного списка в `custom.yaml` (override per user).
- [ ] Тест на 2-3 юзерах (через новую подписку).
- [ ] Merge в `master` + рассылка обновления.

### Совместимость клиентов (mihomo-core)

| Клиент | `type: smart` | `tun.exclude-package` | `respect-rules` DNS | LightGBM |
|---|---|---|---|---|
| **mihomo for Android** (com.github.metacubex.mihomo) | ❌ `proxy group unsupported: smart` | ✅ | ✅ | ❌ |
| **FlClash** (Android/Windows) | ❌ | ✅ | ✅ | ❌ |
| **Clash Verge Rev** | ❌ | ✅ | ✅ | ❌ |
| **NekoBox for Android** | ❌ | ✅ | ✅ | ❌ |
| **mihomo-smart** (AUR community fork) | ✅ | ✅ | ✅ | ✅ |
| **mihomo-bin** (Linux) | ❌ (stable) / ✅ (smart-fork) | ✅ | ✅ | ❌ / ✅ |
| **Stash / Shadowrocket / Loon** (iOS) | ❌ | ❌ (другая структура) | ❌ | ❌ |

**Вывод:** в нашей подписке не используем `type: smart` и `lgbm-*` (PR #2711 ещё open). Вместо этого — `url-test` (выбор по latency) + `fallback` (запасной).

### Открытые вопросы

- **Ватсап/инста у «кого-то»** — диагностика на их девайсах. Возможно, `force-dns-mapping: true` ломает UDP-аудио (фейковые IP). Если да — попробовать `false` (см. legiz-конфиг: у него `parse-pure-ip: true` + `override-destination: false`).
- **Telegram DNS** — `PROCESS-NAME-REGEX` поднят, но если не поможет, надо вернуть `fake-ip` режим + добавить `+.telegram.org`, `+.t.me` в `fake-ip-filter` (чтобы они шли через real-IP, а не fake-IP).
- **legiz ru-bundle** — у нас `RULE-SET,ru-bundle,🌍 VPN` — нагрузка на сервер большая (там mrs на тысячи записей). Подумать, нужен ли он для AWG-юзеров, или достаточно `GEOIP,RU,DIRECT`.

### Полезные ссылки

- PR smart group: https://github.com/MetaCubeX/mihomo/pull/2711 (open)
- Mihomo wiki (rules): https://wiki.metacubex.one/en/config/rules/
- Mihomo wiki (tun): https://wiki.metacubex.one/en/config/inbound/tun/
- Legiz rule-sets: https://github.com/legiz-ru/mihomo-rule-sets
