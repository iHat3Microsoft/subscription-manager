# Архитектура и База Знаний (Mihomo Subscription Manager)

## Что мы сделали
1. **Автоматизированный бэкенд** на Node.js для сборки мастер-конфигов и proxy-providers.
2. **Парсинг всего:** Поддерживаются `vpn://` ссылки (с асинхронным детектом zlib), обычные текстовые ссылки (`vless://`) и чистые `.conf` контейнеры Wireguard/Amnezia.
3. **Безопасность (Anti-Bruteforce):** Ссылки генерируются с 32-значным 128-битным токеном (`token.txt`), защищая подписки от подбора (как в Marzban/Remnawave).
4. **Умный автовыбор:** Сделали группы `fallback` "ленивыми" (`lazy: true`) и с повышенным таймаутом (5000мс). Теперь переключение серверов не рвет SSH-сессии при малейшем лаге сети.
5. **Динамические селекторы:** Серверы подтягиваются в выпадающие списки приложений (YouTube, Discord и т.д.) через `use: ['foreign_servers', 'ru_servers']`, полностью копируя ручное поведение прошлой GUI-версии.

## Что можно использовать прямо сейчас (Скрытые фичи)

### Кастомные настройки (custom.yaml)
В папку любого пользователя (например, `data/Brother/custom.yaml`) можно положить файл. Он **автоматически сольется** с глобальным шаблоном!

- **Открытие селектора 18+:**
  ```yaml
  proxy-groups:
    - name: '🔞 18+'
      hidden: false
  ```

- **Сервер по умолчанию (вместо Автовыбора):**
  ```yaml
  proxy-groups:
    - name: '🌍 Иностранные серверы'
      proxies:
        - Нидерланды10гбит # Теперь будет по умолчанию!
        - ♻️ Автовыбор (Иностранные)
  ```

- **Добавление External UI / API для конкретного юзера:**
  ```yaml
  external-controller: 127.0.0.1:9090
  secret: "super-secret"
  ```

- **Специфичные правила маршрутизации:**
  ```yaml
  rules:
    - DOMAIN-SUFFIX,drom.ru,🇷🇺 Российские серверы
  ```

### Красивая плашка с гигабайтами (в Caddyfile)
Если вы хотите, чтобы клиенты (FlClash/Shadowrocket) показывали плашку `Использовано 0 / 1.00 TB`, добавьте в `/etc/caddy/Caddyfile` внутрь домена `sub.k3k.lol` строку:
```caddyfile
header /configs/* Subscription-Userinfo "upload=0; download=0; total=1099511627776; expire=1893456000"
```

## Что еще надо бы сделать в будущем (Планы)

1. **Скрипт `add_user.sh` для сервера AWG:** 
   Скрипт на чистом Bash для VPS в Нидерландах и Москве, который будет мгновенно выдавать ключи `.conf` через `wg genkey` без необходимости запускать приложение Amnezia и тыкать кнопки руками.
2. **Настоящий биллинг / Revoke ключей:**
   Переход на `awg-server` (тот самый бинарник на Go) или Marzban. Текущий менеджер подписок **не умеет** блокировать доступ к самому VPN-серверу. Он лишь генерирует файл для телефона. Реально ограничить гигабайты и заблокировать пользователя можно только на самом VPN-сервере.
3. **Авто-деплой через GitHub Actions:**
   Настроить CI/CD, чтобы вы могли закидывать `.conf` файлы прямо на GitHub со своего ПК, а сервер сам бы стягивал их, запускал `build.js` и обновлял Caddy.

## v0.2 (dev) — в работе

Работа в ветке `dev`. Подробности в `TODO.md`. Кратко:

- **DNS:** `redir-host` (без fake-ip), `respect-rules: true`, `proxy-server-nameserver` через тег `#PROXY`, `nameserver-policy` для `+.omarchy.org` / `+.archlinux.org` / `+.github.com` / `+.githubusercontent.com` / `+.jsdelivr.net` / `raw.githubusercontent.com` — DNS для Arch/pacman идёт через VPN (раньше шёл напрямую к CF и падал на DPI).
- **`tun.exclude-package`:** 526 пакетов из legiz (Сбер, ВК, Авито, Яндекс, Озон, Wildberries, банки, операторы, и т.д.). Это **нативный** Android-эквивалент системной галки «Запретить выбранные приложения» (VPN-интерфейс не создаётся для пакета → приложение не «видит» VPN).
- **`RULE-SET,ru_apps,DIRECT` (legiz):** запасной process-name список для десктопа + Android-приложений не из exclude.
- **`data/ru-apps-classical.yaml`:** 526 правил `PROCESS-NAME,xxx` в формате rule-provider. Можно захостить на GitHub Pages / на сервере и подключить через `RULE-SET,ru_apps_custom,DIRECT`.
- **Telegram:** `PROCESS-NAME-REGEX,(?i).*telegram.*` поднят в правило (лечит redmi/mido/crDroid, где DNS через `fake-ip` не работал).
- **AI:** убран дубль правила.
- **`tun.route-exclude-address`:** убран `198.18.0.0/15` (ломает fake-ip, при redir-host не нужен).
- **`proxy-groups`:** `⚡️ Fastest` (url-test) — основная автобалансировка, `♻️ Автовыбор` (fallback) — запасной. **`📊 Smart` (type: smart) и `lgbm-*` top-level убраны** — не поддерживается в mihomo for Android / FlClash / Clash Verge / NekoBox. PR MetaCubeX/mihomo#2711 ещё open.
- **`src/build.js` НЕ изменён** — он остаётся в `master` как был, чтобы не сломать прод-подписку. Изменения переносятся только после твоего зелёного теста test-config.
