# Session notes — ZCode refactor session, 2026-08-17

Everything important from the session so nothing is lost when the Windows
dev environment is wiped.

## Branches pushed to GitLab (origin)

| Branch | Commits | Content |
|---|---|---|
| `refactor/cleanup` | 8 (0a73f2c→3e86e5a) | parsers fix, dead code, dedupe, generateConfig split, Amnezia parser unification, token perms, package.json, CI echo→real checks |
| `refactor/round2` | 16 (0a73f2c→02dc829) | above + mk_safe hang fix, bash+node regression tests, BASE_URL slash, ru-app-list self-heal, sync.bash, README, fully commented CI, editorconfig |
| `ci/deploy-pipeline` | 1 (from master) | Disabled pipeline (web-only gate + placeholder), real pipeline in comments, ready to enable |

`master` was NEVER touched. All branches fork from it.

## Bugs found and fixed

### 1. parseSubscriptionUrl not exported (REAL BUG on master)
`src/parsers.js` had the function but not in `module.exports`. `src/build.js`
calls it as fallback when an HTTP subscription URL is unreachable. Without the
export: TypeError → buildAll() catches it silently (`.catch(console.error)`)
→ remaining users in that run are NOT rebuilt. Triggered only when a sub URL
in someone's keys is dead at build time. Verified: reproduced on clean master
by putting `https://example.com/dead` in `data/*/foreign/`.

### 2. mk_safe infinite loop (REAL BUG on master)
In `sub_vless.sh` the trim loop used `${s%_}` (strip trailing underscore).
A name >30 chars not ending in `_` never shortened → `while` loop forever.
Fixed: `${s%?}` strips last char regardless. Also capped collision suffix
at 32 chars (base:27 + _xxxx) so Marzban API doesn't 422.

### 3. ru-app-list cache corruption (REAL BUG on master)
Half-written `data/.ru-app-list.yaml` (killed curl, full disk) → either throws
or parses as empty → `tun.exclude-package` silently disappears for ALL users
until someone manually `rm` the cache. Fixed: detect corrupt/empty/zero-package
cache → delete and re-download once per build.

### 4. BASE_URL trailing slash (edge case)
`BASE_URL=https://host/` produced double-slash URLs (`//providers/...`).
Fixed: `.replace(/\/+$/, '')` at startup.

### 5. sync.bash only shipped build.js
After parser changes, hot-patching only build.js → new build with old parser.
Fixed: rsync both build.js + parsers.js.

### 6. dead uniqueServerName in parsers.js
Referenced undefined `state` variable, never exported, never called. Removed.

## What changed vs master (verified: golden YAML output byte-identical)

All changes to `src/build.js` and `src/parsers.js` produce identical output
for the same input. Tested with fixture data (WG .conf, vless://, vmess://,
Amnezia JSON, dead URL, custom.yaml) against a master golden snapshot.

## Architecture notes for future reference

- `src/build.js` — main entrypoint. Reads `data/<user>/{ru,foreign}/*`, parses
  keys, generates `public/providers/<TOKEN>_{ru,foreign}.yaml` and
  `public/configs/<TOKEN>` (no extension).
- `src/parsers.js` — all protocol parsers (vless/vmess/ss/trojan/hy2/tuic),
  Amnezia JSON/WG .conf parsing, share-link decoding. Exports used by build.js.
- Token files: `data/<user>/token.txt` — now created with mode 0600.
- `npm test` runs: node --check on sources + parser regression tests +
  shell helper tests. Works on `node:20-alpine` and `bash:5` (CI).
- Shell scripts (gen.sh, sub.sh, sub_vless.sh, add_vless.sh, adduser.sh) —
  SSH orchestration, not tested by CI (require remote hosts).
- `Caddyfile` serves `public/` at the configured domain.
- Deploy: SSH forced command `/usr/local/bin/subman-deploy.sh` on `deploy-bot`
  user (ops/setup-deploy-bot.sh). No CI workflow exists in repo.
- README had a stale "GitHub Actions" section referencing `.github/workflows/deploy.yml`
  which does not exist — replaced with the actual SSH deploy flow.

## dev branch analysis (NOT DONE — for next session)

The user mentioned a `dev` branch that existed on the frozen GitHub account
but was never pushed to GitLab. Some changes may be lost. TODO:
- Check if `dev` exists on GitLab (`git fetch origin dev` or check web UI)
- Check the GitHub mirror (if accessible)
- Compare dev vs master to identify lost changes
- Determine if anything is needed for production

## TODO for next session

- [ ] Review `dev` branch (GitHub mirror / GitLab) — identify lost changes
- [ ] `package.json` says license "ISC" but `LICENSE` is GPLv3 — intentional?
- [ ] Consider: `gen.sh` uses python3 inline scripts — could be pure bash/awk
- [ ] Consider: `sub_vless.sh` at 488 lines could benefit from splitting
- [ ] `Caddyfile` has hardcoded domain — could use env var or Caddy snippet

---

## Session notes — Anti-Censorship & Architecture Overhaul, 2026-10-16

### 1. Контекст проекта и цели
- **Главная цель:** Цензуроустойчивый VPN для пользователей в РФ со сплит-туннелированием по принципу «включил и забыл». Максимальная производительность, комфорт, отсутствие необходимости включать/выключать VPN для банков и российских сайтов.
- **Инфраструктура:** VPS с протоколами Hysteria 2 (основной скоростной UDP), AmneziaWG 3.1 (L3 UDP туннель) и VLESS Reality TCP (аварийный резерв при блокировке UDP). Раздача подписок через Caddy (`public/configs/<TOKEN>`).

### 2. Что важно знать новому агенту в первую очередь

#### А. Почему конфиг строится через JS-функции в `src/build.js`, а не из YAML-шаблона:
- Текстовый `replace` / string-injection в YAML ломает отступы при динамических списках (530+ Android пакетов, переменное число нод).
- `yaml.load()` при парсинге шаблона сносит все комментарии.
- Чистые JS-функции (`buildDns()`, `buildTun()`, `buildRules()`) строго типизированы, тестируются через `node --check` и `npm test`, поддерживают per-user `custom.yaml` deep merge.

#### Б. Схема безопасного тестирования (`buildvpn test / revert / promote`):
- Состояние режима хранится в `data/.build-mode.json` (`stable` | `test` | `promoted`).
- **`buildvpn test` (или `node src/build.js test`):**
  - Пересобирает **только** профиль тестера (`TEST_USER`, по умолчанию `Me`) — не трогает и не перезаписывает 20+ других пользователей.
  - Для `Me` генерирует основной файл `${token}` с новыми экспериментальными фичами (IPv6 blackhole, `sticky-sessions` балансировка по умолчанию).
  - Для него же генерирует аварийный файл `${token}_stable` с проверенными стабильными параметрами.
  - Физическая папка `data/Me` **не клонируется**, сохраняя единый источник ключей.
- **`buildvpn revert`:** мгновенный откат всех профилей на стабильный конфиг.
- **`buildvpn promote`:** раскатка проверенных экспериментальных фичей в постоянный стандарт для всех пользователей.

#### В. Иерархия сортировки нод в `sortProxies`:
1. **Ярус скорости:** Ноды с `10G` / `10гбит` всегда идут первыми.
2. **Протокол внутри яруса:** `Hysteria 2` (вес 30) $\rightarrow$ `WireGuard/AWG` (вес 20) $\rightarrow$ `VLESS` (вес 10).
3. **Имя:** по алфавиту.
*Результат:* Fallback-группы всегда держат трафик на быстрых UDP-протоколах (Hysteria 2 / AWG), а VLESS висит в самом конце как резерв на случай глушения UDP.

#### Г. Архитектура DNS (Решение дедлоков и ловушек `respect-rules`):
- `nameserver`: использует IP-based DoH (`https://1.1.1.1/dns-query#🌍 Иностранные серверы` и `https://8.8.8.8/dns-query#🌍 Иностранные серверы`). Суффикс `#<group>` гарантирует, что DoH идёт через прокси и не утекает в DIRECT из-за `google-geoip` или `MATCH`.
- `proxy-server-nameserver`: использует Яндекс DoH/DoT (`common.dot.dns.yandex.net`, `tls://77.88.8.8`) с суффиксом `#disable-ipv6=true` для первичного резолва доменов VPS без дедлока.
- `direct-nameserver`: Яндекс с `#disable-ipv6=true` — блокирует AAAA-запросы для прямого выхода, исключая ошибки `network is unreachable` в логах.
- `fake-ip`: обязателен. 0 мс задержка старта соединений, DNS заблокированных сайтов резолвится удаленно на европейской ноде без подмен от ТСПУ.

#### Д. Тонкости порядка правил в `rules`:
1. Локальные IPv4 подсети с `no-resolve` и SSH:22.
2. `RULE-SET,my-rules,📋 My Rules` — на самом верху (выше игр и шаблонных приложений) для моментальных ручных разблокировок.
3. Торренты, игры, десктопные `ru_apps`.
4. Реклама: `RULE-SET,oisd_small` (~490 KB, блокирует рекламу Xiaomi/MIUI и мобильных баннеров, не ломая банки и укладываясь в 50 МБ лимит iOS).
5. Целевые сервисы:
   - `🤖 AI (Нейронки)`: всегда на `♻️ Автовыбор (Иностранные)` (fallback), чтобы не флапать IP на ChatGPT/Claude.
   - `▶️ YouTube` & `💬 Discord`: на `♻️ Резерв (RU -> EU)` (держит RU-ноду для отсутствия рекламы).
   - `🔎 Google`: `DIRECT` $\rightarrow$ `♻️ Автовыбор` $\rightarrow$ `🌍 Иностранные`.
6. Списки блокировок РКН (`ru-bundle`, `ru-blocked` в формате `text`) **строго выше** `DOMAIN-SUFFIX,ru,DIRECT`, иначе заблокированные `.ru`-сайты улетают в DIRECT.
7. Прямой RU-трафик: `ru`, `xn--p1ai` (Punycode, не кириллица!), `su`.
8. Обход блокировки CDN Fastly: `IP-CIDR,151.101.0.0/16,🚫 Заблокированные сайты (RU)` спасает Flathub, Mozilla Sync, OpenStreetMap, Reddit от таймаутов.
9. В самом низу: `GEOIP,RU,DIRECT` и `RULE-SET,rknasnblock,🚫 Заблокированные сайты (RU)` **без `no-resolve`** (чтобы неизвестные домены резолвились и проверялись по IP-базам блокировок).
10. `IP-ASN` удален целиком — вся Meta покрыта `facebook-ips.mrs`, что экономит ~20 МБ RAM (`GeoASN.dat` не загружается).
11. Завершающее: `MATCH,🌐 Остальной трафик (MATCH)`.

#### Е. Специфика версий Mihomo:
- `global-client-fingerprint` в Mihomo v1.19.x удален из корня конфига (вызывает `3008error`). `client-fingerprint` задается внутри настроек конкретных прокси-узлов.
- `tun.stack`: намеренно не указывается в генерируемом конфиге. Новые клиенты (v1.19.32+) автоматически подставляют дефолтный `mips` (Mihomo IP Stack), а старые клиенты (до v1.19.31) — дефолтный `gvisor`. Явное указание `stack: mips` приводило к сбою обновления на старых версиях.
- `strategy: sticky-sessions` автоматически склеивает поддомены по eTLD+1 и кэширует сессию на 10 минут.
