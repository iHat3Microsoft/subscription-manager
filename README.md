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
   npm ci --omit=dev
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
   - Основной конфиг для пользователя: `public/configs/<TOKEN>` (без расширения)

   В консоли вы увидите готовую защищенную ссылку!

3. **Использование в Mihomo (Clash Meta):**
   Отправьте пользователю защищенную ссылку из консоли. Например:
   `https://sub.k3k.lol/configs/3f9b2d8e4c1a6f...`
   
   Пользователь вставляет эту ссылку в приложение. Приложение скачивает конфиг, который в свою очередь автоматически подтягивает `ru_servers` и `foreign_servers` из файлов провайдеров. Интервал обновления провайдеров установлен на 1 час (3600 сек).

## Смена домена (после 10 июня)

Когда вы поменяете домен:
1. Замените домен в `/etc/caddy/Caddyfile` и перезапустите Caddy (`sudo systemctl restart caddy`).
2. Перегенерируйте конфиги с новым URL:
   ```bash
   BASE_URL=https://newdomain.com node src/build.js
   ```
3. Клиентам придется обновить ссылку в приложении один раз. После этого автообновление будет работать через новый домен.

## Автодеплой через SSH (deploy-bot)

Деплой живёт на самом сервере как SSH forced command — workflow-файла в
репозитории нет. GitLab CI в этой ветке закомментирован целиком
(см. `.gitlab-ci.yml`): раскомментируешь, когда будешь готов добавлять
секретные переменные.

### 1) Настройка безопасного deploy-пользователя на Ubuntu 24

```bash
sudo adduser --disabled-password --gecos "" deploy-bot
sudo install -o root -g root -m 755 ops/subman-deploy.sh /usr/local/bin/subman-deploy.sh
sudo chown -R deploy-bot:deploy-bot /opt/subscription-manager
```

Сгенерируйте SSH-ключ локально, публичный ключ добавьте в
`/home/deploy-bot/.ssh/authorized_keys` с жесткими ограничениями:

```text
command="/usr/local/bin/subman-deploy.sh",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA... deploy
```

```bash
sudo mkdir -p /home/deploy-bot/.ssh
sudo chown deploy-bot:deploy-bot /home/deploy-bot/.ssh
sudo chmod 700 /home/deploy-bot/.ssh
sudo nano /home/deploy-bot/.ssh/authorized_keys
sudo chown deploy-bot:deploy-bot /home/deploy-bot/.ssh/authorized_keys
sudo chmod 600 /home/deploy-bot/.ssh/authorized_keys
```

### 2) Что делает деплой

`/usr/local/bin/subman-deploy.sh`:
- `git pull --ff-only origin master`
- `npm ci --omit=dev`
- `BASE_URL=https://sub.k3k.lol node src/build.js`

Ручной запуск: `ssh deploy-bot@<host>` — forced command отработает
независимо от переданной команды.

Если деплой когда-нибудь переедет в GitLab CI, понадобятся переменные
`SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `DEPLOY_HOST`, `DEPLOY_USER`,
`DEPLOY_PORT`, `BASE_URL` (закомментированная джоба `deploy:production`
в `.gitlab-ci.yml` уже их ждёт).
