# test-config.yaml (dev branch)

Это **тестовый** конфиг mihomo. Сгенерирован из ru-app-list.yaml (legiz) с дедупликацией.
Содержит:
- DNS через PROXY (Quad9 → Cloudflare → Google)
- redir-host (без fake-ip — лечит Telegram на redmi/mido/crDroid)
- `tun.exclude-package` (526 пакетов) — нативное исключение как "Запретить выбранные приложения"
- `RULE-SET,ru_apps,DIRECT` + process-name rules как запасной способ
- 📊 Smart (LightGBM) + ⚡️ Fastest (url-test) — обе группы
- `PROCESS-NAME-REGEX,(?i).*telegram.*` поднят на правило Telegram (лечит redmi/mido)
- БЕЗ `proxy-providers` — впиши `proxies:` руками

## Как тестировать

1. Открой `public/configs/test-config.yaml`
2. Впиши внизу (замени `proxies: []`) свои прокси, например:
   ```yaml
   proxies:
     - name: "Мой AWG"
       type: wireguard
       server: 1.2.3.4
       port: 51820
       ip: 10.0.0.2
       private-key: "..."
       public-key: "..."
       # ... и т.д.
   ```
3. Положи в mihomo-клиент (mihomo for Android / FlClash / Clash Verge / и т.п.)
4. Если всё ок — переносим в `src/build.js`

## Список пакетов

См. `data/ru-packages.txt`.
