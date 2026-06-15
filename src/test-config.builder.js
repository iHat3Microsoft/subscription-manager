#!/usr/bin/env node
// Test config generator for mihomo — run without proxy-providers.
// Reads ru-app-list.yaml from legiz, dedupes packages, emits:
//   - /tmp/opencode/test-config/test-config.yaml  (full mihomo config, no proxy-providers)
//   - data/ru-packages.txt                       (deduped package list, for review)
//   - data/ru-apps-classical.yaml                (rule-provider format PROCESS-NAME,xxx — for hosting)
//
// Run: node src/test-config.builder.js
// After: open /tmp/opencode/test-config/test-config.yaml, manually add your `proxies:` block.

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const ROOT = path.join(__dirname, '..');
const RU_APP_LIST_URL = 'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/ru-app-list.yaml';
const RU_APP_LIST_LOCAL = path.join(ROOT, 'public/configs/_source/ru-app-list.yaml');
const OUT_CONFIG = '/tmp/opencode/test-config/test-config.yaml';
const OUT_PKG_LIST = path.join(ROOT, 'data/ru-packages.txt');
const OUT_RULE_PROVIDER = path.join(ROOT, 'data/ru-apps-classical.yaml');

function loadPackages() {
  let raw;
  if (fs.existsSync(RU_APP_LIST_LOCAL)) {
    raw = fs.readFileSync(RU_APP_LIST_LOCAL, 'utf8');
    console.log('[info] using local ru-app-list.yaml');
  } else {
    console.log('[info] downloading ru-app-list.yaml from legiz ...');
    const { execSync } = require('child_process');
    fs.mkdirSync(path.dirname(RU_APP_LIST_LOCAL), { recursive: true });
    execSync(`curl -fsSL "${RU_APP_LIST_URL}" -o "${RU_APP_LIST_LOCAL}"`);
    raw = fs.readFileSync(RU_APP_LIST_LOCAL, 'utf8');
  }
  const parsed = yaml.load(raw);
  const pkgs = [];
  for (const line of parsed.payload || []) {
    const m = /^PROCESS-NAME,(.+)$/.exec(line);
    if (m) pkgs.push(m[1]);
  }
  return [...new Set(pkgs)].sort();
}

function buildConfig(packages) {
  return {
    'profile-name': 'k3k.lol VPN (TEST)',

    mode: 'rule',
    ipv6: false,
    'log-level': 'info',
    'allow-lan': false,
    'unified-delay': true,
    'tcp-concurrent': true,

    // ---------- LightGBM/smart отключены (см. комментарий в DNS-секции) ----------

    profile: {
      'store-selected': true,
    },

    // ---------- LightGBM/smart-группа отключены: ни у одного из целевых клиентов
    // (mihomo for Android, FlClash, Clash Verge, NekoBox) нет поддержки type: smart
    // в текущей стабильной версии. PR MetaCubeX/mihomo#2711 ещё не смёржен.
    // Реальная автобалансировка делается через url-test (⚡️ Fastest) ниже. ----------

    // ---------- DNS (redir-host, через PROXY, fallback'и) ----------
    dns: {
      enable: true,
      listen: '127.0.0.1:6868',
      ipv6: false,
      'prefer-ipv4': true,
      'enhanced-mode': 'redir-host',
      'use-hosts': true,
      'use-system-hosts': true,
      'respect-rules': true,
      'default-nameserver': [
        '9.9.9.9',
        '1.1.1.1',
        '8.8.8.8'
      ],
      'proxy-server-nameserver': [
        'https://dns.quad9.net/dns-query#PROXY',
        'https://cloudflare-dns.com/dns-query#PROXY'
      ],
      'direct-nameserver': [
        '77.88.8.8',
        '8.8.8.8'
      ],
      nameserver: [
        'tls://9.9.9.9',
        'https://dns.quad9.net/dns-query',
        'https://cloudflare-dns.com/dns-query'
      ],
      fallback: [
        'tls://1.1.1.1',
        'https://cloudflare-dns.com/dns-query'
      ],
      'fallback-filter': {
        geoip: true,
        'geoip-code': 'CN',
        ipcidr: ['240.0.0.0/4'],
        domain: ['+.google.com', '+.facebook.com', '+.youtube.com']
      },
      'nameserver-policy': {
        'geosite:category-ru': ['77.88.8.8', '8.8.8.8'],
        '+.omarchy.org': ['https://dns.quad9.net/dns-query#PROXY'],
        '+.archlinux.org': ['https://dns.quad9.net/dns-query#PROXY'],
        '+.github.com': ['https://dns.quad9.net/dns-query#PROXY'],
        '+.githubusercontent.com': ['https://dns.quad9.net/dns-query#PROXY'],
        '+.jsdelivr.net': ['https://dns.quad9.net/dns-query#PROXY'],
        'raw.githubusercontent.com': ['https://dns.quad9.net/dns-query#PROXY']
      }
    },

    // ---------- TUN (Android exclude-package — НАТИВНО как "Запретить выбранные приложения") ----------
    tun: {
      enable: true,
      stack: 'mixed',
      'auto-route': true,
      'auto-detect-interface': true,
      'dns-hijack': ['any:53', 'tcp://any:53'],
      'strict-route': true,
      'route-exclude-address': [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
        '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
        '192.88.99.0/24', '192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24',
        '224.0.0.0/3', '::/127', 'fc00::/7', 'fe80::/10', 'ff00::/8'
      ],
      'exclude-package': packages
    },

    // ---------- Sniffer ----------
    sniffer: {
      enable: true,
      'force-dns-mapping': true,
      'parse-pure-ip': true,
      sniff: {
        HTTP: { ports: [80, '8080-8880'], 'override-destination': true },
        TLS: { ports: [443, 8443] }
      }
    },

    // ---------- Прокси (ЗАГЛУШКА — заполни вручную или подключи свой proxy-provider) ----------
    proxies: [],

    // ---------- Группы ----------
    'proxy-groups': [
      // url-test — основная автобалансировка (выбирает прокси с мин. latency каждые 300с)
      {
        name: '⚡️ Fastest',
        type: 'url-test',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 300,
        tolerance: 150,
        use: ['foreign_servers']
      },
      // Fallback (ленивый) — запасной, если все foreign отвалились или Fastest не выбрал никого
      {
        name: '♻️ Автовыбор (Иностранные)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 300,
        timeout: 5000,
        lazy: true,
        use: ['foreign_servers']
      },
      {
        name: '♻️ Автовыбор (Россия)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 300,
        timeout: 5000,
        lazy: true,
        use: ['ru_servers']
      },
      {
        name: '♻️ Резерв (RU -> EU)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 300,
        timeout: 5000,
        lazy: true,
        use: ['ru_servers', 'foreign_servers']
      },
      {
        name: '🌍 Иностранные серверы',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Global.png',
        proxies: ['⚡️ Fastest', '♻️ Автовыбор (Иностранные)', '🇷🇺 Российские серверы', 'DIRECT'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🚫 Заблокированные сайты (RU)',
        type: 'select',
        icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/Blocked.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы', 'DIRECT'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🔞 18+',
        type: 'select',
        hidden: true,
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Pornhub.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы', 'DIRECT'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🚫 Реклама',
        type: 'select',
        icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/AdBlock.png',
        proxies: ['REJECT', 'DIRECT', '🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🌐 Остальной трафик (MATCH)',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Auto.png',
        proxies: ['DIRECT', '🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '💬 Discord',
        type: 'select',
        icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/Discord.png',
        proxies: ['♻️ Резерв (RU -> EU)', '🇷🇺 Российские серверы', '🌍 Иностранные серверы'],
        use: ['ru_servers', 'foreign_servers']
      },
      {
        name: '📞 WhatsApp',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/WhatsApp.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы', 'DIRECT'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '▶️ YouTube',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/YouTube.png',
        proxies: ['♻️ Резерв (RU -> EU)', '🇷🇺 Российские серверы', '🌍 Иностранные серверы'],
        use: ['ru_servers', 'foreign_servers']
      },
      {
        name: '📸 Instagram & Threads',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Instagram.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '➤ Telegram',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Telegram.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы', 'DIRECT'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🎵 TikTok',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/TikTok.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🤖 AI (Нейронки)',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Spark.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '👾 Brawl Stars',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🎮 Roblox',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '👥 Facebook',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Facebook.png',
        proxies: ['🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '🇷🇺 Российские серверы',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Russia.png',
        proxies: ['♻️ Автовыбор (Россия)'],
        use: ['ru_servers']
      },
      {
        name: '🎮 Игры (DIRECT)',
        type: 'select',
        hidden: true,
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png',
        proxies: ['DIRECT', '🌍 Иностранные серверы', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      },
      {
        name: '📋 My Rules',
        type: 'select',
        hidden: true,
        proxies: ['🌍 Иностранные серверы', 'DIRECT', '🇷🇺 Российские серверы'],
        use: ['foreign_servers', 'ru_servers']
      }
    ],

    // ---------- Rule providers ----------
    'rule-providers': {
      oisd_big: {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/big.mrs',
        path: './rule-sets/oisd_big.mrs', interval: 86400
      },
      discord_voiceips: {
        type: 'http', behavior: 'ipcidr', format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/discord-voice-ip-list.mrs',
        path: './rule-sets/discord_voiceips.mrs', interval: 86400
      },
      'category-porn': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-porn.mrs',
        path: './rule-sets/category-porn.mrs', interval: 86400
      },
      'geosite-youtube': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/youtube.mrs',
        path: './rule-sets/youtube.mrs', interval: 86400
      },
      'geosite-discord': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/discord.mrs',
        path: './rule-sets/discord.mrs', interval: 86400
      },
      'geosite-instagram': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/instagram.mrs',
        path: './rule-sets/instagram.mrs', interval: 86400
      },
      'geosite-facebook': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/facebook.mrs',
        path: './rule-sets/facebook.mrs', interval: 86400
      },
      'geosite-tiktok': {
        type: 'http', behavior: 'domain', format: 'yaml',
        url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/tiktok.yaml',
        path: './rule-sets/tiktok.yaml', interval: 86400
      },
      'geosite-supercell': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/supercell.mrs',
        path: './rule-sets/supercell.mrs', interval: 86400
      },
      'geosite-roblox': {
        type: 'http', behavior: 'domain', format: 'yaml',
        url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/roblox.yaml',
        path: './rule-sets/roblox.yaml', interval: 86400
      },
      'geosite-soundcloud': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/soundcloud.mrs',
        path: './rule-sets/soundcloud.mrs', interval: 86400
      },
      'telegram-domains': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/telegram.mrs',
        path: './rule-sets/telegram-domains.mrs', interval: 86400
      },
      'telegram-ips': {
        type: 'http', behavior: 'ipcidr', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs',
        path: './rule-sets/telegram-ips.mrs', interval: 86400
      },
      'geosite-openai': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/openai.mrs',
        path: './rule-sets/openai.mrs', interval: 86400
      },
      'google-gemini': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/google-gemini.mrs',
        path: './rule-sets/google-gemini.mrs', interval: 86400
      },
      'geosite-anthropic': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/anthropic.mrs',
        path: './rule-sets/anthropic.mrs', interval: 86400
      },
      'my-rules': {
        type: 'http', behavior: 'classical', format: 'yaml',
        url: 'https://raw.githubusercontent.com/chm0d777/mihomo-config/main/my-rules.yaml',
        path: './rule-sets/my-rules.yaml', interval: 86400
      },
      'ru-blocked': {
        type: 'http', behavior: 'classical', format: 'yaml',
        url: 'https://cdn.jsdelivr.net/gh/shvchk/unblock-net/lists/clash/ru-blocked',
        path: './rule-sets/ru-blocked.yaml', interval: 86400
      },
      'ru_apps': {
        type: 'http', behavior: 'classical', format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/ru-app-list.yaml',
        path: './rule-sets/ru-apps.yaml', interval: 86400
      },
      'whatsapp-domains': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/whatsapp.mrs',
        path: './rule-sets/whatsapp-domains.mrs', interval: 86400
      },
      'facebook-ips': {
        type: 'http', behavior: 'ipcidr', format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/facebook.mrs',
        path: './rule-sets/facebook-ips.mrs', interval: 86400
      },
      'torrent-trackers': {
        type: 'http', behavior: 'domain', format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-trackers.mrs',
        path: './rule-sets/torrent-trackers.mrs', interval: 86400
      },
      'torrent-clients': {
        type: 'http', behavior: 'classical', format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-clients.yaml',
        path: './rule-sets/torrent-clients.yaml', interval: 86400
      },
      'games-direct': {
        type: 'http', behavior: 'classical', format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/games-direct.yaml',
        path: './rule-sets/games-direct.yaml', interval: 86400
      },
      'discord_vc': {
        type: 'inline', behavior: 'classical',
        payload: [
          'AND,((IP-CIDR,138.128.136.0/21),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,162.158.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,172.64.0.0/13),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,34.0.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,34.2.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,35.192.0.0/12),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,35.208.0.0/12),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,5.200.14.128/25),(NETWORK,udp),(DST-PORT,50000-50100))',
          'AND,((IP-CIDR,66.22.192.0/18),(NETWORK,udp),(DST-PORT,50000-50100))'
        ]
      }
    },

    // ---------- Rules ----------
    rules: [
      'RULE-SET,games-direct,🎮 Игры (DIRECT)',
      'RULE-SET,torrent-clients,DIRECT',
      'PROCESS-NAME-REGEX,(?i).*torrent.*,DIRECT',
      'RULE-SET,torrent-trackers,🌍 Иностранные серверы',
      // RU-приложения → DIRECT (process-name для десктопа + Android package)
      'RULE-SET,ru_apps,DIRECT',
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'OR,((RULE-SET,geosite-openai),(RULE-SET,google-gemini),(RULE-SET,geosite-anthropic),(DOMAIN-KEYWORD,grok),(DOMAIN-SUFFIX,grok.com),(DOMAIN-SUFFIX,appcenter.ms),(DOMAIN-KEYWORD,copilot),(DOMAIN-SUFFIX,copilot.microsoft.com),(PROCESS-NAME-REGEX,(?i).*(chatgpt|claude|copilot|gemini|cursor|windsurf|cline|antigravity).*),(PROCESS-NAME,com.openai.chatgpt),(PROCESS-NAME,com.anthropic.claude),(PROCESS-NAME,com.microsoft.copilot),(PROCESS-NAME,ai.perplexity.app.android)),🤖 AI (Нейронки)',
      'RULE-SET,oisd_big,🚫 Реклама',
      'RULE-SET,geosite-youtube,▶️ YouTube',
      'OR,((RULE-SET,geosite-discord),(RULE-SET,discord_voiceips),(PROCESS-NAME,Discord.exe)),💬 Discord',
      'RULE-SET,discord_vc,💬 Discord',
      'OR,((RULE-SET,facebook-ips),(RULE-SET,whatsapp-domains)),📞 WhatsApp',
      'RULE-SET,geosite-instagram,📸 Instagram & Threads',
      'RULE-SET,geosite-facebook,👥 Facebook',
      // Telegram: process-name поднят наверх (лечит redmi/mido, где домен не резолвится)
      'OR,((RULE-SET,telegram-ips),(RULE-SET,telegram-domains),(PROCESS-NAME-REGEX,(?i).*telegram.*),(PROCESS-NAME,org.telegram.messenger),(PROCESS-NAME,org.telegram.plus),(PROCESS-NAME,com.tgraph.TelegameX),(PROCESS-NAME,com.exteragram.messenger),(PROCESS-NAME,com.iwayworks.ixgram)),➤ Telegram',
      'RULE-SET,geosite-tiktok,🎵 TikTok',
      'RULE-SET,geosite-soundcloud,🌍 Иностранные серверы',
      'RULE-SET,geosite-supercell,👾 Brawl Stars',
      'RULE-SET,geosite-roblox,🎮 Roblox',
      'RULE-SET,ru-blocked,🚫 Заблокированные сайты (RU)',
      'RULE-SET,category-porn,🔞 18+',
      'RULE-SET,my-rules,📋 My Rules',
      'GEOIP,RU,DIRECT',
      'DOMAIN-SUFFIX,ru,DIRECT',
      'DOMAIN-SUFFIX,рф,DIRECT',
      'DOMAIN-SUFFIX,su,DIRECT',
      'MATCH,🌐 Остальной трафик (MATCH)'
    ]
  };
}

function main() {
  const packages = loadPackages();
  console.log(`[info] ${packages.length} unique RU package(s) loaded`);

  fs.mkdirSync(path.dirname(OUT_PKG_LIST), { recursive: true });
  fs.writeFileSync(OUT_PKG_LIST, packages.join('\n') + '\n');
  console.log(`[ok] wrote ${OUT_PKG_LIST}`);

  const config = buildConfig(packages);
  fs.mkdirSync(path.dirname(OUT_CONFIG), { recursive: true });
  fs.writeFileSync(OUT_CONFIG, yaml.dump(config, { indent: 2, lineWidth: -1, noRefs: true }));
  console.log(`[ok] wrote ${OUT_CONFIG} (${(fs.statSync(OUT_CONFIG).size / 1024).toFixed(1)} KB)`);

  // Дополнительно: rule-provider формат (для подключения через URL)
  // Можно захостить на GitHub Pages / сервере и подключить как
  //   - RULE-SET,ru_apps_custom,DIRECT
  const ruleProviderPayload = {
    payload: packages.map(p => `PROCESS-NAME,${p}`)
  };
  fs.mkdirSync(path.dirname(OUT_RULE_PROVIDER), { recursive: true });
  fs.writeFileSync(OUT_RULE_PROVIDER, yaml.dump(ruleProviderPayload, { indent: 2, lineWidth: -1 }));
  console.log(`[ok] wrote ${OUT_RULE_PROVIDER} (${packages.length} PROCESS-NAME rules)`);
}

main();
