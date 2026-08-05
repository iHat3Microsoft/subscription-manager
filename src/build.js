const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const yaml = require('js-yaml');
const parsers = require('./parsers');

const DATA_DIR = path.join(__dirname, '..', 'data');
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const PROVIDERS_DIR = path.join(PUBLIC_DIR, 'providers');
const CONFIGS_DIR = path.join(PUBLIC_DIR, 'configs');

// Create output directories
if (!fs.existsSync(PUBLIC_DIR)) fs.mkdirSync(PUBLIC_DIR, { recursive: true });
if (!fs.existsSync(PROVIDERS_DIR)) fs.mkdirSync(PROVIDERS_DIR, { recursive: true });
if (!fs.existsSync(CONFIGS_DIR)) fs.mkdirSync(CONFIGS_DIR, { recursive: true });

// Environment or default base URL for providers
const BASE_URL = process.env.BASE_URL || 'https://sub.k3k.lol';

// Кэш списка RU-пакетов (legiz) — чтобы не качать при каждом билде
// Список маленький (~20 KB), кладём рядом с data/, но в .gitignore
const RU_APP_LIST_URL = 'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/ru-app-list.yaml';
const RU_APP_LIST_CACHE = path.join(DATA_DIR, '.ru-app-list.yaml');

function loadRuPackages() {
  let raw;
  if (fs.existsSync(RU_APP_LIST_CACHE)) {
    raw = fs.readFileSync(RU_APP_LIST_CACHE, 'utf8');
  } else {
    console.log('[info] downloading ru-app-list.yaml from legiz ...');
    const { execSync } = require('child_process');
    fs.mkdirSync(path.dirname(RU_APP_LIST_CACHE), { recursive: true });
    execSync(`curl -fsSL "${RU_APP_LIST_URL}" -o "${RU_APP_LIST_CACHE}"`);
    raw = fs.readFileSync(RU_APP_LIST_CACHE, 'utf8');
  }
  const parsed = yaml.load(raw);
  const pkgs = [];
  for (const line of (parsed && parsed.payload) || []) {
    const m = /^PROCESS-NAME,(.+)$/.exec(line);
    if (m) pkgs.push(m[1]);
  }
  return [...new Set(pkgs)].sort();
}

// Helper to parse a single text chunk (file content)
async function parseProxy(content) {
  content = content.trim();
  if (!content) return null;

  // Try JSON first (AmneziaWG/Xray containers)
  try {
    const json = JSON.parse(content);
    if (json.containers) {
      for (const container of json.containers) {
        if (container.awg) {
          const p = parsers.parseAmneziaAwgProxy(json, container);
          if (p) return p;
        } else if (container.wireguard) {
          const p = parsers.parseAmneziaWireGuardProxy(json, container);
          if (p) return p;
        } else if (container.xray) {
          const p = parsers.parseAmneziaVlessProxy(json, container);
          if (p) return p;
        }
      }
    }
  } catch (e) {
    // Not JSON
  }

  // Try parsing as share link or vpn://
  const urlProxy = await parsers.parseProxyUrl(content);
  if (urlProxy) return urlProxy;

  // If it's a raw .conf file text (like standard Wireguard/AmneziaWG)
  // We can wrap it in a mock JSON structure to feed it to our parser, or 
  // we can manually parse it if needed. For now, since the user said 
  // AmneziaWG gives JSON keys, we rely on JSON.
  // Wait! A .conf file is INI format. The frontend didn't natively parse pure INI without the json wrapper.
  // If we need pure .conf parsing, we can add it here.

  // Try raw WG/AWG .conf format
  if (content.includes('[Interface]') && content.includes('[Peer]')) {
    return parsers.parseWireGuardConfig(content);
  }

  return null;
}

// Generate the complete Mihomo config template for a user
function generateConfig(userName, ruProviderUrl, foreignProviderUrl, excludePackages = []) {
  return {
    mode: 'rule',
    ipv6: false,
    'log-level': 'info',
    'allow-lan': false,
    'unified-delay': true,
    'tcp-concurrent': true,

    dns: {
      enable: true,
      listen: '127.0.0.1:6868',
      ipv6: false,
      'prefer-ipv4': true,
      'enhanced-mode': 'fake-ip',
      'fake-ip-range': '198.18.0.0/15',
      'fake-ip-filter': [
        '*.lan',
        '*.local',
        '+.msftconnecttest.com',
        '+.telegram.org',
        '+.t.me'
      ],
      'default-nameserver': ['8.8.8.8', '1.1.1.1', '9.9.9.9'],
      nameserver: [
        'https://8.8.8.8/dns-query',
        'https://cloudflare-dns.com/dns-query'
      ],
      'nameserver-policy': {
        'geosite:category-ru': ['77.88.8.8', '8.8.8.8']
      }
    },

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
      'exclude-package': excludePackages
    },

    sniffer: {
      enable: true,
      'force-dns-mapping': true,
      'parse-pure-ip': true,
      sniff: {
        HTTP: { ports: [80, '8080-8880'], 'override-destination': true },
        TLS: { ports: [443, 8443] }
      }
    },

    'proxy-providers': {
      ru_servers: {
        type: 'http',
        interval: 3600,
        url: ruProviderUrl,
        path: './proxy-providers/ru_servers.yaml',
        'health-check': {
          enable: true,
          interval: 600,
          url: 'https://www.gstatic.com/generate_204'
        }
      },
      foreign_servers: {
        type: 'http',
        interval: 3600,
        url: foreignProviderUrl,
        path: './proxy-providers/foreign_servers.yaml',
        'health-check': {
          enable: true,
          interval: 600,
          url: 'https://www.gstatic.com/generate_204'
        }
      }
    },

    'proxy-groups': [
      {
        name: '♻️ Автовыбор (Иностранные)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 60,
        timeout: 5000,
        'max-failed-times': 3,
        use: ['foreign_servers']
      },
      {
        name: '♻️ Автовыбор (Россия)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 60,
        timeout: 5000,
        'max-failed-times': 3,
        use: ['ru_servers']
      },
      {
        name: '♻️ Резерв (RU -> EU)',
        type: 'fallback',
        hidden: true,
        url: 'https://www.gstatic.com/generate_204',
        interval: 60,
        timeout: 5000,
        'max-failed-times': 3,
        use: ['ru_servers', 'foreign_servers']
      },
      {
        name: '🌍 Иностранные серверы',
        type: 'select',
        icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Global.png',
        proxies: ['♻️ Автовыбор (Иностранные)'],
        use: ['foreign_servers']
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
        proxies: ['♻️ Резерв (RU -> EU)', '🇷🇺 Российские серверы', '🌍 Иностранные серверы', 'DIRECT'],
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
        proxies: ['♻️ Резерв (RU -> EU)', '🇷🇺 Российские серверы', '🌍 Иностранные серверы', 'DIRECT'],
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

    'rule-providers': {
      oisd_big: {
        type: 'http',
        behavior: 'domain',
        format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/big.mrs',
        path: './rule-sets/oisd_big.mrs',
        interval: 86400
      },
      discord_voiceips: {
        behavior: 'ipcidr',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/discord-voice-ip-list.mrs',
        path: './rule-sets/discord_voiceips.mrs',
        interval: 86400
      },
      'category-porn': {
        type: 'http',
        behavior: 'domain',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-porn.mrs',
        path: './rule-sets/category-porn.mrs',
        interval: 86400
      },
      'geosite-youtube': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/youtube.mrs',
        path: './rule-sets/youtube.mrs',
        interval: 86400
      },
      'geosite-discord': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/discord.mrs',
        path: './rule-sets/discord.mrs',
        interval: 86400
      },
      'geosite-instagram': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/instagram.mrs',
        path: './rule-sets/instagram.mrs',
        interval: 86400
      },
      'geosite-facebook': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/facebook.mrs',
        path: './rule-sets/facebook.mrs',
        interval: 86400
      },
      'geosite-meta': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/meta.mrs',
        path: './rule-sets/meta.mrs',
        interval: 86400
      },
      'geosite-tiktok': {
        behavior: 'domain',
        type: 'http',
        format: 'yaml',
        url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/tiktok.yaml',
        path: './rule-sets/tiktok.yaml',
        interval: 86400
      },
      'geosite-supercell': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/supercell.mrs',
        path: './rule-sets/supercell.mrs',
        interval: 86400
      },
      'geosite-soundcloud': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/soundcloud.mrs',
        path: './rule-sets/soundcloud.mrs',
        interval: 86400
      },
      'telegram-domains': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/telegram.mrs',
        path: './rule-sets/telegram-domains.mrs',
        interval: 86400
      },
      'telegram-ips': {
        behavior: 'ipcidr',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs',
        path: './rule-sets/telegram-ips.mrs',
        interval: 86400
      },
      'geosite-openai': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/openai.mrs',
        path: './rule-sets/openai.mrs',
        interval: 86400
      },
      'google-gemini': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/google-gemini.mrs',
        path: './rule-sets/google-gemini.mrs',
        interval: 86400
      },
      'geosite-anthropic': {
        behavior: 'domain',
        type: 'http',
        format: 'mrs',
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/anthropic.mrs',
        path: './rule-sets/anthropic.mrs',
        interval: 86400
      },
      'my-rules': {
        type: 'http',
        behavior: 'classical',
        format: 'yaml',
        url: 'https://raw.githubusercontent.com/chm0d777/mihomo-config/main/my-rules.yaml',
        path: './rule-sets/my-rules.yaml',
        interval: 86400
      },
      'ru-blocked': {
        behavior: 'classical',
        type: 'http',
        format: 'yaml',
        url: 'https://cdn.jsdelivr.net/gh/shvchk/unblock-net/lists/clash/ru-blocked',
        path: './rule-sets/ru-blocked.yaml',
        interval: 86400
      },
      'ru_apps': {
        type: 'http',
        behavior: 'classical',
        format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/ru-app-list.yaml',
        path: './rule-sets/ru-apps.yaml',
        interval: 86400
      },
      'whatsapp-domains': {
        type: 'http',
        behavior: 'domain',
        format: 'mrs',
        interval: 86400,
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/whatsapp.mrs',
        path: './rule-sets/whatsapp-domains.mrs'
      },
      'facebook-ips': {
        type: 'http',
        behavior: 'ipcidr',
        format: 'mrs',
        interval: 86400,
        url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/facebook.mrs',
        path: './rule-sets/facebook-ips.mrs'
      },
      'torrent-trackers': {
        type: 'http',
        behavior: 'domain',
        format: 'mrs',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-trackers.mrs',
        path: './rule-sets/torrent-trackers.mrs',
        interval: 86400
      },
      'torrent-clients': {
        type: 'http',
        behavior: 'classical',
        format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-clients.yaml',
        path: './rule-sets/torrent-clients.yaml',
        interval: 86400
      },
      'games-direct': {
        type: 'http',
        behavior: 'classical',
        format: 'yaml',
        url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/games-direct.yaml',
        path: './rule-sets/games-direct.yaml',
        interval: 86400
      },
      'discord_vc': {
        type: 'inline',
        behavior: 'classical',
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

    rules: [
      'RULE-SET,oisd_big,🚫 Реклама',
      'RULE-SET,games-direct,🎮 Игры (DIRECT)',
      'RULE-SET,torrent-clients,DIRECT',
      'PROCESS-NAME-REGEX,(?i).*torrent.*,DIRECT',
      'RULE-SET,torrent-trackers,🌍 Иностранные серверы',
      'RULE-SET,ru_apps,DIRECT',
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'AND,((NETWORK,tcp),(DST-PORT,22)),DIRECT',
      'PROCESS-NAME,ssh,DIRECT',
      'RULE-SET,geosite-youtube,▶️ YouTube',
      'OR,((RULE-SET,geosite-discord),(RULE-SET,discord_voiceips),(PROCESS-NAME,Discord.exe)),💬 Discord',
      'RULE-SET,discord_vc,💬 Discord',
      'PROCESS-NAME,com.instagram.android,📸 Instagram & Threads',
      'PROCESS-NAME,com.instagram.barcelona,📸 Instagram & Threads',
      'OR,((RULE-SET,geosite-instagram),(RULE-SET,geosite-meta),(DOMAIN-SUFFIX,cdninstagram.com),(DOMAIN-SUFFIX,fbcdn.net),(DOMAIN-SUFFIX,fbsbx.com),(DOMAIN-SUFFIX,instagram.com),(DOMAIN-SUFFIX,threads.net),(DOMAIN-SUFFIX,graph.instagram.com),(DOMAIN-SUFFIX,graph.facebook.com),(DOMAIN-KEYWORD,instagram)),📸 Instagram & Threads',
      'IP-ASN,32934,📸 Instagram & Threads',
      'OR,((RULE-SET,facebook-ips),(RULE-SET,whatsapp-domains)),📞 WhatsApp',
      'RULE-SET,geosite-facebook,👥 Facebook',
      'OR,((RULE-SET,telegram-ips),(RULE-SET,telegram-domains)),➤ Telegram',
      'PROCESS-NAME-REGEX,(?i).*ayugram.*,➤ Telegram',
      'PROCESS-NAME-REGEX,(?i).*telegram.*,➤ Telegram',
      'PROCESS-NAME,org.telegram.messenger,➤ Telegram',
      'RULE-SET,geosite-tiktok,🎵 TikTok',
      'RULE-SET,geosite-soundcloud,🌍 Иностранные серверы',
      'OR,((RULE-SET,geosite-openai),(RULE-SET,google-gemini),(RULE-SET,geosite-anthropic),(DOMAIN-KEYWORD,grok),(DOMAIN-SUFFIX,grok.com),(DOMAIN-SUFFIX,appcenter.ms),(DOMAIN-KEYWORD,copilot),(DOMAIN-SUFFIX,copilot.microsoft.com),(PROCESS-NAME-REGEX,(?i).*(chatgpt|claude|copilot|gemini|cursor|windsurf|cline|antigravity|opencode).*),(PROCESS-NAME,opencode),(PROCESS-NAME,com.openai.chatgpt),(PROCESS-NAME,com.anthropic.claude),(PROCESS-NAME,com.microsoft.copilot),(PROCESS-NAME,ai.perplexity.app.android)),🤖 AI (Нейронки)',
      'RULE-SET,geosite-supercell,👾 Brawl Stars',
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

// Process all users in the data directory
async function buildAll() {
  if (!fs.existsSync(DATA_DIR)) {
    console.log(`Directory ${DATA_DIR} does not exist. Created it.`);
    fs.mkdirSync(DATA_DIR, { recursive: true });
    return;
  }

  // Загружаем список RU-пакетов (legiz) один раз для всех юзеров
  let ruPackages = [];
  try {
    ruPackages = loadRuPackages();
    console.log(`[info] loaded ${ruPackages.length} RU package(s) for tun.exclude-package`);
  } catch (e) {
    console.error(`[warn] failed to load RU packages: ${e.message}`);
    console.error(`[warn] continuing without tun.exclude-package`);
  }

  const users = fs.readdirSync(DATA_DIR).filter(f => fs.statSync(path.join(DATA_DIR, f)).isDirectory());

  for (const user of users) {
    const userDir = path.join(DATA_DIR, user);
    const ruDir = path.join(userDir, 'ru');
    const foreignDir = path.join(userDir, 'foreign');
    const tokenFile = path.join(userDir, 'token.txt');

    // Безопасность: Генерируем или читаем токен подписки (anti-bruteforce)
    let token = '';
    if (fs.existsSync(tokenFile)) {
      token = fs.readFileSync(tokenFile, 'utf-8').trim();
    } else {
      token = crypto.randomBytes(16).toString('hex');
      fs.writeFileSync(tokenFile, token);
      console.log(`[Info] Generated new secure token for user: ${user}`);
    }

    let ruProxies = [];
    let foreignProxies = [];

    // Parse RU servers
    if (fs.existsSync(ruDir)) {
      const files = fs.readdirSync(ruDir).sort();
      for (const f of files) {
        const content = fs.readFileSync(path.join(ruDir, f), 'utf-8');
        const lines = content.split('\n');
        let validProxies = [];

        for (let i = 0; i < lines.length; i++) {
          const proxy = await parseProxy(lines[i]);
          if (proxy) validProxies.push(proxy);
        }

        if (content.includes('[Interface]') || content.trim().startsWith('{')) {
          const proxy = await parseProxy(content);
          if (proxy) validProxies.push(proxy);
        }

        const baseName = f.replace(/\.[^/.]+$/, "");
        validProxies.forEach((p, idx) => {
          p.name = validProxies.length === 1 ? baseName : `${baseName}-${idx + 1}`;
          ruProxies.push(p);
        });
      }
    }

    // Parse Foreign servers
    if (fs.existsSync(foreignDir)) {
      const files = fs.readdirSync(foreignDir).sort();
      for (const f of files) {
        const content = fs.readFileSync(path.join(foreignDir, f), 'utf-8');
        const lines = content.split('\n');
        let validProxies = [];

        for (let i = 0; i < lines.length; i++) {
          const proxy = await parseProxy(lines[i]);
          if (proxy) validProxies.push(proxy);
        }

        if (content.includes('[Interface]') || content.trim().startsWith('{')) {
          const proxy = await parseProxy(content);
          if (proxy) validProxies.push(proxy);
        }

        const baseName = f.replace(/\.[^/.]+$/, "");
        validProxies.forEach((p, idx) => {
          p.name = validProxies.length === 1 ? baseName : `${baseName}-${idx + 1}`;
          foreignProxies.push(p);
        });
      }
    }

    const sortProxies = (a, b) => {
      const a10g = a.name.includes('10гбит') || a.name.includes('10G') || a.name.includes('10gbit');
      const b10g = b.name.includes('10гбит') || b.name.includes('10G') || b.name.includes('10gbit');
      if (a10g && !b10g) return -1;
      if (!a10g && b10g) return 1;
      return a.name.localeCompare(b.name);
    };

    // Deduplicate
    ruProxies = [...new Map(ruProxies.map(item => [item.name, item])).values()].sort(sortProxies);
    foreignProxies = [...new Map(foreignProxies.map(item => [item.name, item])).values()].sort(sortProxies);

    if (ruProxies.length === 0 && foreignProxies.length === 0) {
      console.log(`[Warning] No proxies found for user ${user}. Skipping.`);
      continue;
    }

    const ruPath = path.join(PROVIDERS_DIR, `${token}_ru.yaml`);
    const foreignPath = path.join(PROVIDERS_DIR, `${token}_foreign.yaml`);
    const configPath = path.join(CONFIGS_DIR, `${token}`);

    // Write Providers
    fs.writeFileSync(ruPath, yaml.dump({ proxies: ruProxies }, { indent: 2, lineWidth: -1 }));
    fs.writeFileSync(foreignPath, yaml.dump({ proxies: foreignProxies }, { indent: 2, lineWidth: -1 }));

    // Write Master Config
    const masterConfig = generateConfig(
      user,
      `${BASE_URL}/providers/${token}_ru.yaml`,
      `${BASE_URL}/providers/${token}_foreign.yaml`,
      ruPackages
    );

    // Вшиваем имя профиля прямо в YAML (поддерживается многими клиентами)
    masterConfig['profile-name'] = 'uvx.lol VPN';

    // --- ПОЛЬЗОВАТЕЛЬСКИЕ ПЕРЕОПРЕДЕЛЕНИЯ (custom.yaml) ---
    const customPath = path.join(userDir, 'custom.yaml');
    if (fs.existsSync(customPath)) {
      try {
        const customConfig = yaml.load(fs.readFileSync(customPath, 'utf8'));
        if (customConfig && typeof customConfig === 'object') {
          for (const key of Object.keys(customConfig)) {
            if (key === 'proxy-groups' && Array.isArray(customConfig[key])) {
              // Сливаем группы прокси по имени
              for (const cg of customConfig[key]) {
                const existingGroup = masterConfig['proxy-groups'].find(g => g.name === cg.name);
                if (existingGroup) {
                  Object.assign(existingGroup, cg);
                } else {
                  masterConfig['proxy-groups'].push(cg);
                }
              }
            } else if (key === 'rules' && Array.isArray(customConfig[key])) {
              // Добавляем кастомные правила в САМОЕ НАЧАЛО
              masterConfig.rules = [...customConfig[key], ...masterConfig.rules];
            } else if (key === 'tun-exclude-packages' && Array.isArray(customConfig[key])) {
              // Override списка исключённых Android-пакетов (tun.exclude-package)
              if (!masterConfig.tun) masterConfig.tun = {};
              masterConfig.tun['exclude-package'] = customConfig[key];
            } else if (key === 'rule-providers' && customConfig[key] && typeof customConfig[key] === 'object' && !Array.isArray(customConfig[key])) {
              // Сливаем rule-providers по имени: существующие переопределяем частично,
              // отсутствующие добавляем. Не затираем базовый набор (oisd_big, games-direct, ...).
              if (!masterConfig['rule-providers'] || typeof masterConfig['rule-providers'] !== 'object') {
                masterConfig['rule-providers'] = {};
              }
              for (const rpName of Object.keys(customConfig['rule-providers'])) {
                const existing = masterConfig['rule-providers'][rpName];
                if (existing && typeof existing === 'object') {
                  Object.assign(existing, customConfig['rule-providers'][rpName]);
                } else {
                  masterConfig['rule-providers'][rpName] = customConfig['rule-providers'][rpName];
                }
              }
            } else {
              // Перезаписываем или добавляем другие ключи (external-ui, secret и т.д.)
              masterConfig[key] = customConfig[key];
            }
          }
          console.log(`[Info] Merged custom.yaml for user ${user}`);
        }
      } catch (e) {
        console.error(`[Error] Failed to parse custom.yaml for user ${user}:`, e.message);
      }
    }
    // ------------------------------------------------------

    fs.writeFileSync(configPath, yaml.dump(masterConfig, { indent: 2, lineWidth: -1 }));
    console.log(`[Success] Generated configs for user: ${user}`);
    console.log(`  -> Subscription Link: ${BASE_URL}/configs/${token}`);
  }
}

buildAll().catch(console.error);
