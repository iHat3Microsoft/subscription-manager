# Mihomo Subscription Manager

Это бекенд для автоматизации управления конфигами и ключами AmneziaWG/Wireguard/VLESS.

## Установка на Ubuntu

1. **Установите Node.js и Caddy:**
   ```bash
   curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
   sudo apt-get install -y nodejs
   
   sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
   sudo apt update
   sudo apt install caddy
   ```

2. **Загрузите этот проект:**
   Скопируйте папку `subscription-manager` на ваш сервер (например, в `/opt/mihomo-subscriptions/`).
   ```bash
   cd /opt/mihomo-subscriptions
   npm install js-yaml
   ```

3. **Настройте домен (Caddy):**
   Отредактируйте `Caddyfile`, вписав ваш домен. По умолчанию стоит `sub.k3k.lol`.
   ```bash
   sudo cp Caddyfile /etc/caddy/Caddyfile
   sudo systemctl restart caddy
   ```

## Использование

1. **Добавление пользователей и серверов:**
   В папке `data` создайте папку с именем пользователя. Внутри неё создайте папки `ru` и `foreign`.
   Положите ключи (текстовые файлы с `vpn://...` или файлы конфигурации `.conf` от AmneziaWG) в соответствующие папки.

   ```text
   data/
   ├── Vasya/
   │   ├── ru/
   │   │   └── moscow.conf
   │   └── foreign/
   │       └── netherlands.conf
   ```

2. **Генерация ссылок подписок:**
   Запустите скрипт сборки. Вы можете передать базовый URL через переменную окружения `BASE_URL`.
   ```bash
   BASE_URL=https://sub.k3k.lol node src/build.js
   ```

   Скрипт сгенерирует криптографически безопасный токен (anti-bruteforce) для пользователя, сохранит его в `data/Vasya/token.txt`, и создаст файлы в папке `public/`:
   - Провайдеры: `public/providers/<TOKEN>_ru.yaml` и `public/providers/<TOKEN>_foreign.yaml`
   - Основной конфиг для пользователя: `public/configs/<TOKEN>.yaml`

   В консоли вы увидите готовую защищенную ссылку!

3. **Использование в Mihomo (Clash Meta):**
   Отправьте пользователю защищенную ссылку из консоли. Например:
   `https://sub.k3k.lol/configs/3f9b2d8e4c1a6f....yaml`
   
   Пользователь вставляет эту ссылку в приложение. Приложение скачивает конфиг, который в свою очередь автоматически подтягивает `ru_servers` и `foreign_servers` из файлов провайдеров. Интервал обновления провайдеров установлен на 1 час (3600 сек).

## Смена домена (после 10 июня)

Когда вы поменяете домен:
1. Замените домен в `/etc/caddy/Caddyfile` и перезапустите Caddy (`sudo systemctl restart caddy`).
2. Перегенерируйте конфиги с новым URL:
   ```bash
   BASE_URL=https://newdomain.com node src/build.js
   ```
3. Клиентам придется обновить ссылку в приложении один раз. После этого автообновление будет работать через новый домен.
