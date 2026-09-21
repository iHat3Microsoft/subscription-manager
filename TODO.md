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

---

## 2026-09-22 — Пакет улучшений VPN-сервиса

### Порядок выполнения
1. Photopea → my-rules.yaml
2. Health-check + убрать Москву + скрыть селекторы → build.js
3. ru-app-list TTL-автообновление → build.js
4. AWG 3.x парсер → parsers.js
5. IPv6 утечки → build.js
6. Google обратно → build.js + my-rules.yaml
7. legiz ru-bundle/rknasnblock → build.js
8. GitLab CI/CD → .gitlab-ci.yml
9. AWG 3.0 gen.sh wrapper → инструкция

---

### [HIGH-1] Health-check менее агрессивный + убрать Москву + скрыть селекторы

**Файл:** `src/build.js`

**Проблема:** Fallback-группы пингуют gstatic каждые 60 сек. Если gstatic
не отвечает (а сервер жив), fallback считает сервер мёртвым → рвёт соединение.
Юзеры выбирают Москву в селекторах где она бесполезна.
Слишком много видимых селекторов — путает юзеров.

**Health-check URL:** Оставляем `gstatic.com/generate_204`. По ресёрчу:
gstatic из РФ периодически режется DPI, но Cloudflare блокируется не реже.
Google CDN стабильнее в РФ. Проблема не в URL а в агрессивности пинга.

**Что менять:**

A) Proxy-provider health-check (строки 238-253 в build.js):
   - `interval: 600` → `900` (15 мин вместо 10)
   - Добавить `lazy: true` — пинговать только при первом использовании

B) Fallback-группы (строки 259-287):
   - `interval: 60` → `300` (5 мин — "пингануть 1 раз, перепинговать если упал")
   - `max-failed-times: 3` → `5`
   - Добавить `lazy: true` во все 3 fallback-группы

C) Убрать `ru_servers` из `use:` ВСЕХ select-групп кроме:
   - `💬 Discord` — оставить (через `♻️ Резерв (RU -> EU)`)
   - `▶️ YouTube` — оставить (через `♻️ Резерв (RU -> EU)`)
   - `🇷🇺 Российские серверы` — оставить (его назначение)
   - Скрытые fallback `♻️ Автовыбор (Россия)` / `♻️ Резерв` — оставить

   Убрать `ru_servers` из use: И `🇷🇺 Российские серверы` из proxies: у:
   `🚫 Заблокированные сайты (RU)`, `🔞 18+`, `🚫 Реклама`,
   `🌐 Остальной трафик`, `📞 WhatsApp`, `📸 Instagram`, `➤ Telegram`,
   `🎵 TikTok`, `🤖 AI`, `👾 Brawl Stars`, `👥 Facebook`,
   `🎮 Игры (DIRECT)`, `📋 My Rules`.

D) Скрыть большинство селекторов (`hidden: true`).
   Видимые (hidden: false или без hidden) ТОЛЬКО:
   - `🌍 Иностранные серверы`
   - `🌐 Остальной трафик (MATCH)`
   - `🚫 Реклама`
   Всё остальное hidden: true:
   `🚫 Заблокированные сайты`, `🔞 18+`, `💬 Discord`, `📞 WhatsApp`,
   `▶️ YouTube`, `📸 Instagram`, `➤ Telegram`, `🎵 TikTok`,
   `🤖 AI`, `👾 Brawl Stars`, `👥 Facebook`, `🇷🇺 Российские серверы`,
   `🎮 Игры`, `📋 My Rules`.

---

### [HIGH-2] Photopea в my-rules.yaml

**Файл:** `my-rules.yaml`

Добавить в конец payload:
```yaml
# Photopea (онлайн фоторедактор)
- DOMAIN-SUFFIX,photopea.com
- DOMAIN-KEYWORD,photopea
```

---

### [HIGH-3] Автообновление ru-app-list (TTL)

**Файл:** `src/build.js`, функция `loadRuPackages()` (строки 25-43)

**Текущее:** build.js скачивает ru-app-list.yaml с legiz 1 раз в
`data/.ru-app-list.yaml` и больше не обновляет. Список 530+ PROCESS-NAME.
Источник: `https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/ru-app-list.yaml`
Это тот же список что в runtime rule-provider `ru_apps` (строка 556).
Дублирование нужно: tun.exclude-package (Android) + RULE-SET ru_apps (десктоп).

**Что менять:**
- Добавить TTL-проверку в `loadRuPackages()`:
  если `fs.statSync(RU_APP_LIST_CACHE).mtime` старше 7 дней → перескачать.
- При ошибке скачивания — использовать старый кэш (graceful degradation).
- Логировать `[info] ru-app-list cache expired, re-downloading...`

---

### [HIGH-4] Поддержка AWG 3.x в парсере

**Файл:** `src/parsers.js`

**Источник:** Коммит `f24241f` в `123jjck/mihomo-configurator` (app/parsers.js).
Клон апстрима уже в `~/mihomo-antigravity/mihomo-configurator/`.

**Что нового в AWG 3.x (mihomo поддерживает с недавних версий):**

AWG 3.0 добавил поля в [Interface]:
  `HeaderProtectionKey` → `header-protection-key` (строка, base64)
  `ContentPaddingAddition` → `content-padding-addition` (int или range "0-32")
  `RekeyAfterTime` → `rekey-after-time` (int или range)
  `RekeyTimeout` → `rekey-timeout` (int или range)
  `RejectAfterTime` → `reject-after-time` (int или range)
  `KeepaliveTimeout` → `keepalive-timeout` (int или range)
  `MaxHandshakeAttempts` → `max-handshake-attempts` (int или range)

AWG 3.1 добавил:
  `RandomTrailers` → `random-trailers` (bool)
  `DisableCookies` → `disable-cookies` (bool)

AWG 3.x УБРАЛ (v3 device отвергает, crashing if present):
  `J1`, `J2`, `J3`, `Itime` — помечены `legacyOnly`

КРИТИЧНО: для v3 ОБЯЗАТЕЛЬНО `version: 3` в `amnezia-wg-option`,
иначе mihomo запустит legacy AWG device и упадёт.

**Что менять в parsers.js (портирование из апстрима):**

1. Заменить ручные if-ы в `collectAwgOptions()` (строки 733-769) на
   массив `AWG_FIELD_SPECS` с метаданными:
   ```js
   const AWG_FIELD_SPECS = [
     { key: 'Jc', out: 'jc', parse: asAwgInt },
     { key: 'Jmin', out: 'jmin', parse: asAwgInt },
     // ... все старые поля ...
     { key: 'J1', out: 'j1', parse: normalizeAwgValue, v15: true, legacyOnly: true },
     { key: 'Itime', out: 'itime', parse: asAwgInt, v15: true, legacyOnly: true },
     // v3 новые:
     { key: 'HeaderProtectionKey', out: 'header-protection-key', parse: normalizeAwgValue, v3: true },
     { key: 'ContentPaddingAddition', out: 'content-padding-addition', parse: asAwgIntOrRange, v3: true },
     { key: 'RekeyAfterTime', out: 'rekey-after-time', parse: asAwgIntOrRange, v3: true },
     { key: 'RekeyTimeout', out: 'rekey-timeout', parse: asAwgIntOrRange, v3: true },
     { key: 'RejectAfterTime', out: 'reject-after-time', parse: asAwgIntOrRange, v3: true },
     { key: 'KeepaliveTimeout', out: 'keepalive-timeout', parse: asAwgIntOrRange, v3: true },
     { key: 'MaxHandshakeAttempts', out: 'max-handshake-attempts', parse: asAwgIntOrRange, v3: true },
     { key: 'RandomTrailers', out: 'random-trailers', parse: asAwgBool, v3: true, v31: true },
     { key: 'DisableCookies', out: 'disable-cookies', parse: asAwgBool, v3: true, v31: true },
   ];
   ```

2. Добавить `asAwgBool`:
   `const asAwgBool = v => /^(1|true|yes|on)$/i.test(normalizeAwgValue(v));`

3. Обновить `hasAnyAwgKey()` — использовать AWG_FIELD_SPECS.some().

4. Обновить `collectAwgOptions(obj)` → `collectAwgOptions(get, rawVersion)`:
   - get = функция-геттер (для .conf: `k => iface[k]`, для JSON: `k => clientConfig[k]`)
   - Парсить все поля через AWG_FIELD_SPECS
   - Детектить hasV3, hasV31 по наличию v3/v31-полей
   - Вызвать normalizeAwgVersion с флагами
   - Вызвать buildAwgOption для фильтрации по версии

5. Добавить `normalizeAwgVersion(rawVersion, flags)`:
   - `'3.1'` → '3.1'
   - `'3'/'3.0'` → flags.hasV31 ? '3.1' : '3.0'
   - `'2'/'2.0'` → '2.0', `'1.5'` → '1.5', `'1'/'1.0'` → '1.0'
   - auto: hasV31→'3.1', hasV3→'3.0', hasV20→'2.0', hasV15→'1.5', else '1.0'

6. Добавить `buildAwgOption(parsed, version)`:
   - v3 = version.startsWith('3')
   - v3: `{version: 3}` + все поля КРОМЕ legacyOnly
   - legacy: `{}` + все поля КРОМЕ v3-only
   - Это критично: v3 device крашится если получит J1/Itime

7. Обновить `parseAmneziaAwgProxy()` (строка 834-846):
   - Был: `const { awg } = collectAwgOptions(clientConfig);`
   - Стал: `const { awg, version } = collectAwgOptions(awgLookup(clientConfig), protocolConfig.protocol_version);`
   - Добавить `proxy.awgVersion = version;`

8. Обновить `parseWireGuardConfig()` (строка 1002-1004):
   - Был: `const { awg } = collectAwgOptions(iface);`
   - Стал: `const { awg, version } = collectAwgOptions(k => getAwgKey(iface, k), '');`
   - Добавить `proxy.awgVersion = version;`

Ссылка для сравнения: `~/mihomo-antigravity/mihomo-configurator/app/parsers.js`
(апстрим parsers.js с коммитом f24241f уже склонирован).

---

### [HIGH-5] IPv6 — устранить DNS-утечки

**Файл:** `src/build.js`

**Текущее:** `ipv6: false` (строка 176) + `dns.ipv6: false` (строка 185).
Полный запрет. Если ISP раздаёт IPv6, ОС может слать AAAA-запросы
мимо TUN → утечка реального IP.

**Что менять:**
- Строка 176: `ipv6: false` → `ipv6: true`
  (mihomo ПРИНИМАЕТ IPv6-пакеты в TUN, не пропускает мимо)
- Строка 185: `dns.ipv6: false` — ОСТАВИТЬ
  (не резолвит AAAA → нет IPv6 DNS-ответов → нет утечек)
- Строка 186: `'prefer-ipv4': true` — ОСТАВИТЬ
- TUN секция (строка 206-220): добавить `'inet6-address': 'fd00::1/128'`
  (назначить fake IPv6 на TUN-интерфейс → перехватывать IPv6 трафик)
- `route-exclude-address` — IPv6 loopback/link-local уже есть, ОК.

Логика: `ipv6: true` = TUN захватывает IPv6. `dns.ipv6: false` = AAAA
не резолвятся → весь трафик IPv4 через прокси. IPv6 не утекает.

Тестировать на `browserleaks.com/ipv6` (уже в my-rules).

---

### [MEDIUM-6] Вернуть Google

**Файл:** `src/build.js`, `my-rules.yaml`

**Контекст:** Коммит `0d3e4d1` удалил proxy-group `🔎 Google`,
rule-providers `geosite-google` + `google-geoip`,
правило `OR,((RULE-SET,google-geoip),(RULE-SET,geosite-google)),🔎 Google`.
Не делать git revert — порядок правил изменился.

**Добавить заново:**

1. Proxy-group `🔎 Google` в build.js:
   ```js
   {
     name: '🔎 Google',
     type: 'select',
     hidden: true,
     icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Google_Search.png',
     proxies: ['DIRECT', '🌍 Иностранные серверы'],
     use: ['foreign_servers']
   }
   ```
   БЕЗ ru_servers (согласно решению убрать Москву).

2. Rule-providers в build.js:
   ```js
   'geosite-google': {
     behavior: 'domain', type: 'http', format: 'mrs',
     url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google.mrs',
     path: './rule-sets/google.mrs', interval: 86400
   },
   'google-geoip': {
     behavior: 'ipcidr', type: 'http', format: 'mrs',
     url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/google.mrs',
     path: './rule-sets/google-geoip.mrs', interval: 86400
   }
   ```

3. Правило в rules[] — ПОСЛЕ AI-правила (строка 649), ДО ru-blocked:
   `'OR,((RULE-SET,google-geoip),(RULE-SET,geosite-google)),🔎 Google'`

   Порядок важен: Google Gemini матчится AI-правилом раньше (строка 649).
   Остальной Google → `🔎 Google` → DIRECT по умолчанию.

4. Убрать `GEOSITE,google-play` из `my-rules.yaml` строка 85
   (покроется geosite-google).

Google по умолчанию DIRECT. Юзер может переключить на foreign
через custom.yaml (hidden: false + proxies override).

---

### [MEDIUM-7] Добавить legiz ru-bundle + rknasnblock

**Файл:** `src/build.js`

**Контекст:** У нас `ru-blocked` от shvchk — ручная курация
заблокированных сайтов. legiz `ru-bundle` — агрегат из itdoginfo +
no-russia-hosts + antifilter-community + rknasnblock. Более полный список.
Не заменяем shvchk, ДОПОЛНЯЕМ.

re-filter НЕ добавляем — пересекается с ru-bundle, избыточен.

**Добавить в rule-providers:**
```js
'ru-bundle': {
  type: 'http', behavior: 'domain', format: 'mrs',
  url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rule.mrs',
  path: './ru-bundle/rule.mrs', interval: 86400
},
'rknasnblock': {
  type: 'http', behavior: 'ipcidr', format: 'mrs',
  url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rknasnblock.mrs',
  path: './ru-bundle/rknasnblock.mrs', interval: 86400
}
```

**Добавить в rules[] — рядом с `RULE-SET,ru-blocked`:**
```
'RULE-SET,ru-bundle,🚫 Заблокированные сайты (RU)',
'RULE-SET,rknasnblock,🚫 Заблокированные сайты (RU)',
```

---

### [MEDIUM-8] GitLab CI/CD — rsync двух файлов

**Файл:** `.gitlab-ci.yml` (создать в корне проекта)

**Решение:** rsync ТОЛЬКО `src/build.js` и `src/parsers.js` на сервер,
затем запуск buildvpn. Данные юзеров (data/, out_keys/, public/) НЕ трогаются.
git pull НЕ используем — может затереть ключи юзеров в проде.

```yaml
stages:
  - deploy

deploy:
  stage: deploy
  only:
    - master
  before_script:
    - eval $(ssh-agent -s)
    - echo "$DEPLOY_SSH_KEY" | tr -d '\r' | ssh-add -
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - ssh-keyscan -p $DEPLOY_PORT $DEPLOY_HOST >> ~/.ssh/known_hosts
  script:
    - rsync -avz -e "ssh -p $DEPLOY_PORT"
        src/build.js src/parsers.js
        $DEPLOY_USER@$DEPLOY_HOST:/opt/subscription-manager/src/
    - ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST
        "cd /opt/subscription-manager && BASE_URL=https://sub.k3k.lol node src/build.js"
```

Variables в GitLab CI/CD Settings → Variables:
- `DEPLOY_SSH_KEY` (type: File) — приватный SSH-ключ
- `DEPLOY_HOST` — IP или домен сервера
- `DEPLOY_PORT` — SSH порт (обычно 22)
- `DEPLOY_USER` — юзер на сервере (deploy-bot или основной)

---

### [MEDIUM-9] AWG 3.0 генерация юзеров — SCP wrapper

Требует ручного участия на VPN-сервере. Цель: перехватить SCP-команды
AmneziaVPN GUI чтобы понять что именно AWG 3.0 заливает на сервер.

**Инструкция:**

1. На VPN-сервере создать wrapper `/usr/local/bin/scp-logger.sh`:
   ```bash
   #!/bin/bash
   LOG_DIR="$HOME/awg-scp-log"
   mkdir -p "$LOG_DIR"
   TS=$(date +%Y%m%d_%H%M%S)
   echo "$(date) CMD: $SSH_ORIGINAL_COMMAND" >> "$LOG_DIR/$TS.log"
   if [[ "$SSH_ORIGINAL_COMMAND" == scp* ]]; then
     tee "$LOG_DIR/$TS.data" | eval "$SSH_ORIGINAL_COMMAND"
   else
     eval "$SSH_ORIGINAL_COMMAND" 2>&1 | tee "$LOG_DIR/$TS.out"
   fi
   ```
   `chmod +x /usr/local/bin/scp-logger.sh`

2. В `~/.ssh/authorized_keys` для ключа AmneziaVPN добавить forced command:
   ```
   command="/usr/local/bin/scp-logger.sh" ssh-rsa AAAA... amnezia-vpn
   ```

3. Запустить AmneziaVPN GUI → подключиться к серверу → создать юзера.
   Все SCP-операции сохранятся в `~/awg-scp-log/`.

4. Также запустить `amnezia-vpn --cli` для перехвата основных SSH-команд.

5. На основе логов обновить `gen.sh`:
   - Добавить флаг `--awg-version 3`
   - Генерировать HeaderProtectionKey и другие v3-поля
   - Использовать `awg3` вместо `awg` если нужно

---

### [DEFERRED] Десктопные RU-приложения (PROCESS-NAME для Windows/Linux)

Отложено. Не критичная дыра: по IP-листам и доменам (`GEOIP,RU,DIRECT`,
`DOMAIN-SUFFIX,ru,DIRECT`) трафик RU-приложений и так идёт напрямую.
Яндекс.Браузер теоретически может логгировать IP прокси, но при текущей
маршрутизации большая часть его трафика не попадёт в прокси.

Когда вернёмся: legiz `ru-app-list.yaml` содержит только Android package
names (`com.yandex.browser` и т.п.). Для десктопа нужен отдельный
rule-provider с `PROCESS-NAME` для Windows/Linux/macOS exe
(browser.exe, YandexBrowser.exe, mailru.exe и т.д.).
Готового списка не найдено — нужно составлять вручную или regex:
`PROCESS-NAME-REGEX,(?i).*yandex.*,DIRECT` и аналогично.
