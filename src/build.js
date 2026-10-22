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
// (trailing slash is normalized away: BASE_URL=https://host/ must not
// produce double slashes in provider/config URLs)
const BASE_URL = (process.env.BASE_URL || 'https://sub.k3k.lol').replace(/\/+$/, '');

// Кэш списка RU-пакетов (legiz) — чтобы не качать при каждом билде
// Список маленький (~20 KB), кладём рядом с data/, но в .gitignore
const RU_APP_LIST_URL = 'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/ru-app-list.yaml';
const RU_APP_LIST_CACHE = path.join(DATA_DIR, '.ru-app-list.yaml');
const RU_APP_LIST_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days TTL

function parseRuAppList(raw) {
  if (!raw || !raw.trim()) throw new Error('empty cache file');
  const parsed = yaml.load(raw);
  const pkgs = [];
  for (const line of (parsed && parsed.payload) || []) {
    const m = /^PROCESS-NAME,(.+)$/.exec(line);
    if (m) pkgs.push(m[1]);
  }
  return [...new Set(pkgs)].sort();
}

function downloadRuAppList() {
  const { execSync } = require('child_process');
  fs.mkdirSync(path.dirname(RU_APP_LIST_CACHE), { recursive: true });
  execSync(`curl -fsSL "${RU_APP_LIST_URL}" -o "${RU_APP_LIST_CACHE}.tmp"`);
  fs.renameSync(`${RU_APP_LIST_CACHE}.tmp`, RU_APP_LIST_CACHE);
}

function loadRuPackages() {
  const exists = fs.existsSync(RU_APP_LIST_CACHE);
  let isExpired = false;

  if (exists) {
    try {
      const stat = fs.statSync(RU_APP_LIST_CACHE);
      if (Date.now() - stat.mtimeMs > RU_APP_LIST_TTL_MS) {
        isExpired = true;
      } else {
        const pkgs = parseRuAppList(fs.readFileSync(RU_APP_LIST_CACHE, 'utf8'));
        if (pkgs.length > 0) return pkgs;
        console.warn('[warn] ru-app-list cache has 0 packages, re-downloading');
        isExpired = true;
      }
    } catch (e) {
      console.warn(`[warn] ru-app-list cache corrupt (${e.message}), re-downloading`);
      isExpired = true;
    }
  }

  try {
    console.log(isExpired
      ? '[info] ru-app-list cache expired/invalid, re-downloading from legiz ...'
      : '[info] downloading ru-app-list.yaml from legiz ...');
    downloadRuAppList();
    return parseRuAppList(fs.readFileSync(RU_APP_LIST_CACHE, 'utf8'));
  } catch (e) {
    if (exists) {
      console.warn(`[warn] failed to refresh ru-app-list (${e.message}), falling back to existing cache`);
      try {
        return parseRuAppList(fs.readFileSync(RU_APP_LIST_CACHE, 'utf8'));
      } catch {
        throw e;
      }
    }
    throw e;
  }
}

// Helper to parse a single text chunk (file content)
async function parseProxy(content, baseName) {
  content = content.trim();
  if (!content) return null;

  // Try JSON first (AmneziaWG/Xray containers) — same parser as vpn:// links
  try {
    const json = JSON.parse(content);
    if (json.containers) {
      const p = parsers.parseAmneziaVpnJson(json);
      if (p) return p;
    }
  } catch {
    // Not JSON
  }

  // Try HTTP subscription URL -> inline ingest of Marzban-style YAML.
  if (/^https?:\/\//.test(content)) {
    const fetched = await ingestHttpProxyList(content);
    if (fetched && fetched.length > 0) {
      return fetched;
    }
    console.warn(`[warn] failed to ingest proxies from subscription URL in ${baseName}: ${content}`);
    return null;
  }

  // Try parsing as share link or vpn://
  const urlProxy = await parsers.parseProxyUrl(content);
  if (urlProxy) return urlProxy;

  // Raw WG/AWG .conf file (INI format)
  if (content.includes('[Interface]') && content.includes('[Peer]')) {
    return parsers.parseWireGuardConfig(content);
  }

  return null;
}

// In-memory cache of <URL> -> parsed Marzban YAML body.
const _urlCache = new Map();

async function ingestHttpProxyList(url) {
  let body = _urlCache.get(url);
  if (body === undefined) {
    try {
      const { execFileSync } = require('child_process');
      body = execFileSync(
        'curl',
        ['-fsS', '--max-time', '20', '-H', 'User-Agent: clash.meta', url],
        { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' }
      );
    } catch (e) {
      console.error(`[!] could not fetch ${url}: ${e.message.split('\n')[0]}`);
      body = null;
    }
    _urlCache.set(url, body);
  }
  if (!body) return null;
  let doc;
  try {
    doc = yaml.load(body);
  } catch (e) {
    console.error(`[!] could not parse YAML from ${url}`);
    return null;
  }
  if (!doc || !Array.isArray(doc.proxies) || doc.proxies.length === 0) {
    return null;
  }
  return doc.proxies.map((p, i) => {
    if (!p || typeof p !== 'object') return p;
    if (!p.name) p.name = `proxied-${i + 1}`;
    Object.defineProperty(p, '_keepName', { value: true, enumerable: false });
    return p;
  });
}

function isValidProxy(p) {
  if (!p || typeof p !== 'object') return false;
  if (!p.type || typeof p.type !== 'string') return false;
  const server = String(p.server || '').trim();
  const port = Number(p.port);
  if (!server) return false;
  if (!Number.isInteger(port) || port <= 0 || port > 65535) return false;
  p.port = port;
  p.server = server;
  return true;
}

function asProxyList(result, baseName) {
  if (!result) return [];
  const list = Array.isArray(result) ? result : [result];
  return list
    .filter(p => {
      if (!isValidProxy(p)) {
        if (p && typeof p === 'object') {
          console.warn(`[warn] dropping invalid proxy without server/port in ${baseName}: ${JSON.stringify(p)}`);
        }
        return false;
      }
      return true;
    })
    .map((p, idx, arr) => {
      if (!p._keepName) {
        p.name = arr.length === 1 ? baseName : `${baseName}-${idx + 1}`;
      } else if (!p.name) {
        p.name = arr.length === 1 ? baseName : `${baseName}-${idx + 1}`;
      }
      return p;
    });
}

function buildDns() {
  return {
    enable: true,
    listen: '127.0.0.1:6868',
    ipv6: false,
    'cache-algorithm': 'arc',
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.0/15',
    'fake-ip-filter': [
      '*.lan',
      '*.local',
      '+.msftconnecttest.com',
      '+.msftncsi.com',
      '+.telegram.org',
      '+.t.me',
      '+.stun.*'
    ],
    'respect-rules': true,
    'default-nameserver': [
      '77.88.8.8',
      '94.140.14.140'
    ],
    'proxy-server-nameserver': [
      'https://common.dot.dns.yandex.net/dns-query#disable-ipv6=true',
      'tls://77.88.8.8#disable-ipv6=true'
    ],
    'direct-nameserver': [
      'https://common.dot.dns.yandex.net/dns-query#disable-ipv6=true',
      '77.88.8.8#disable-ipv6=true'
    ],
    nameserver: [
      'https://1.1.1.1/dns-query#🌍 Зарубежный сервер',
      'https://8.8.8.8/dns-query#🌍 Зарубежный сервер'
    ],
    'nameserver-policy': {
      'geosite:category-ru': [
        'https://common.dot.dns.yandex.net/dns-query#disable-ipv6=true',
        '77.88.8.8#disable-ipv6=true'
      ],
      '+.ru': [
        'https://common.dot.dns.yandex.net/dns-query#disable-ipv6=true',
        '77.88.8.8#disable-ipv6=true'
      ],
      '+.xn--p1ai': [
        'https://common.dot.dns.yandex.net/dns-query#disable-ipv6=true',
        '77.88.8.8#disable-ipv6=true'
      ]
    }
  };
}

function buildTun(excludePackages, options = {}) {
  const isExp = Boolean(options.experimental);
  const routeExclude = isExp
    ? [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
        '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
        '192.88.99.0/24', '192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24',
        '224.0.0.0/3', 'fc00::/7', 'fe80::/10'
      ]
    : [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
        '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
        '192.88.99.0/24', '192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24',
        '224.0.0.0/3', '::/127', 'fc00::/7', 'fe80::/10', 'ff00::/8'
      ];

  const tun = {
    enable: true,
    'auto-route': true,
    'auto-detect-interface': true,
    'dns-hijack': ['any:53', 'tcp://any:53'],
    'strict-route': true,
    'route-exclude-address': routeExclude,
    'exclude-package': excludePackages
  };

  if (isExp) {
    tun['inet6-address'] = ['fdfe:dcba:9876::1/126'];
  }

  return tun;
}

function buildSniffer() {
  return {
    enable: true,
    'force-dns-mapping': true,
    'parse-pure-ip': true,
    sniff: {
      HTTP: { ports: [80, '8080-8880'], 'override-destination': true },
      TLS: { ports: [443, 8443] }
    },
    'skip-dst-address': [
      '0.0.0.0/8',
      '10.0.0.0/8',
      '100.64.0.0/10',
      '127.0.0.0/8',
      '169.254.0.0/16',
      '172.16.0.0/12',
      '192.0.0.0/24',
      '192.0.2.0/24',
      '192.88.99.0/24',
      '192.168.0.0/16',
      '198.18.0.0/15',
      '198.51.100.0/24',
      '203.0.113.0/24',
      '224.0.0.0/3',
      '::/127',
      'fc00::/7',
      'fe80::/10',
      'ff00::/8'
    ]
  };
}

function httpProxyProvider(url, providerPath) {
  return {
    type: 'http',
    interval: 3600,
    url,
    path: providerPath,
    'health-check': {
      enable: true,
      lazy: true,
      interval: 900,
      url: 'https://www.gstatic.com/generate_204'
    }
  };
}

function buildProxyProviders(ruProviderUrl, foreignProviderUrl) {
  return {
    ru_servers: httpProxyProvider(ruProviderUrl, './proxy-providers/ru_servers.yaml'),
    foreign_servers: httpProxyProvider(foreignProviderUrl, './proxy-providers/foreign_servers.yaml')
  };
}

function buildProxyGroups(options = {}) {
  const isExp = Boolean(options.experimental);
  const foreignProxies = isExp
    ? ['⚡ Параллельно', '♻️ Автовыбор']
    : ['♻️ Автовыбор'];

  const groups = [
    {
      name: '♻️ Автовыбор',
      type: 'fallback',
      hidden: true,
      lazy: true,
      url: 'https://www.gstatic.com/generate_204',
      interval: 120,
      timeout: 5000,
      'max-failed-times': 3,
      use: ['foreign_servers']
    },
    {
      name: '♻️ Автовыбор РФ',
      type: 'fallback',
      hidden: true,
      lazy: true,
      url: 'https://www.gstatic.com/generate_204',
      interval: 120,
      timeout: 5000,
      'max-failed-times': 3,
      use: ['ru_servers']
    },
    {
      name: '♻️ Сначала РФ',
      type: 'fallback',
      hidden: true,
      lazy: true,
      url: 'https://www.gstatic.com/generate_204',
      interval: 120,
      timeout: 5000,
      'max-failed-times': 3,
      use: ['ru_servers', 'foreign_servers']
    }
  ];

  if (isExp) {
    groups.push({
      name: '⚡ Параллельно',
      type: 'load-balance',
      strategy: 'sticky-sessions',
      hidden: true,
      lazy: true,
      url: 'https://www.gstatic.com/generate_204',
      interval: 120,
      timeout: 5000,
      'max-failed-times': 3,
      use: ['foreign_servers']
    });
  }

  groups.push(
    {
      name: '🌍 Зарубежный сервер',
      type: 'select',
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Global.png',
      proxies: foreignProxies,
      use: ['foreign_servers']
    },
    {
      name: '🌐 Остальной трафик',
      type: 'select',
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Auto.png',
      proxies: ['Без VPN (напрямую)', '🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '▶️ YouTube',
      type: 'select',
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/YouTube.png',
      proxies: ['♻️ Сначала РФ', '🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['ru_servers', 'foreign_servers']
    },
    {
      name: '🔎 Google',
      type: 'select',
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Google_Search.png',
      proxies: ['Без VPN (напрямую)', '♻️ Автовыбор', '🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '🚫 Реклама',
      type: 'select',
      icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/AdBlock.png',
      proxies: ['Блокировать', 'Без VPN (напрямую)', '🌍 Зарубежный сервер']
    },
    {
      name: '💬 Discord',
      type: 'select',
      icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/Discord.png',
      proxies: ['♻️ Сначала РФ', '🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['ru_servers', 'foreign_servers']
    },
    {
      name: '🎵 Spotify / SoundCloud',
      type: 'select',
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Spotify.png',
      proxies: ['♻️ Сначала РФ', '🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['ru_servers', 'foreign_servers']
    },
    {
      name: '🚫 Заблокированные сайты (RU)',
      type: 'select',
      hidden: true,
      icon: 'https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/icons/Blocked.png',
      proxies: ['🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['foreign_servers']
    },
    {
      name: '🔞 18+',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Pornhub.png',
      proxies: ['🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['foreign_servers']
    },
    {
      name: '📞 WhatsApp',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/WhatsApp.png',
      proxies: ['🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['foreign_servers']
    },
    {
      name: '📸 Instagram & Threads',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Instagram.png',
      proxies: ['🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '➤ Telegram',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Telegram.png',
      proxies: ['🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['foreign_servers']
    },
    {
      name: '🎵 TikTok',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/TikTok.png',
      proxies: ['🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '🤖 AI (Нейронки)',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Spark.png',
      proxies: ['♻️ Автовыбор', '🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '👾 Brawl Stars',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png',
      proxies: ['🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '👥 Facebook',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Facebook.png',
      proxies: ['🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '🇷🇺 Российские серверы',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Russia.png',
      proxies: ['♻️ Автовыбор РФ'],
      use: ['ru_servers']
    },
    {
      name: '🎮 Игры (DIRECT)',
      type: 'select',
      hidden: true,
      icon: 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png',
      proxies: ['Без VPN (напрямую)', '🌍 Зарубежный сервер'],
      use: ['foreign_servers']
    },
    {
      name: '📋 My Rules',
      type: 'select',
      hidden: true,
      proxies: ['🌍 Зарубежный сервер', 'Без VPN (напрямую)'],
      use: ['foreign_servers']
    }
  );

  return groups;
}

function buildRuleProviders(options = {}) {
  const isBig = options.adblock === 'big';
  const adblockProvider = isBig
    ? {
        oisd_big: {
          type: 'http',
          behavior: 'domain',
          format: 'mrs',
          url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/big.mrs',
          path: './rule-sets/oisd_big.mrs',
          interval: 86400
        }
      }
    : {
        oisd_small: {
          type: 'http',
          behavior: 'domain',
          format: 'mrs',
          url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/small.mrs',
          path: './rule-sets/oisd_small.mrs',
          interval: 86400
        }
      };

  return {
    ...adblockProvider,
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
      format: 'mrs',
      url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/tiktok.mrs',
      path: './rule-sets/tiktok.mrs',
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
    'geosite-spotify': {
      behavior: 'domain',
      type: 'http',
      format: 'mrs',
      url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/spotify.mrs',
      path: './rule-sets/spotify.mrs',
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
    'geosite-google': {
      behavior: 'domain',
      type: 'http',
      format: 'mrs',
      url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google.mrs',
      path: './rule-sets/google.mrs',
      interval: 86400
    },
    'google-geoip': {
      behavior: 'ipcidr',
      type: 'http',
      format: 'mrs',
      url: 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/google.mrs',
      path: './rule-sets/google-geoip.mrs',
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
      url: 'https://gitlab.com/chm0d755/subscription-manager/-/raw/master/my-rules.yaml',
      path: './rule-sets/my-rules.yaml',
      interval: 86400
    },
    'ru-blocked': {
      behavior: 'domain',
      type: 'http',
      format: 'text',
      url: 'https://cdn.jsdelivr.net/gh/shvchk/unblock-net/lists/clash/ru-blocked',
      path: './rule-sets/ru-blocked.txt',
      interval: 86400
    },
    'ru-bundle': {
      type: 'http',
      behavior: 'domain',
      format: 'mrs',
      url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rule.mrs',
      path: './rule-sets/ru-bundle.mrs',
      interval: 86400
    },
    'rknasnblock': {
      type: 'http',
      behavior: 'ipcidr',
      format: 'mrs',
      url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rknasnblock.mrs',
      path: './rule-sets/rknasnblock.mrs',
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
    discord_vc: {
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
  };
}

function buildRules(options = {}) {
  const isExp = Boolean(options.experimental);
  const isBig = options.adblock === 'big';
  const adblockRule = isBig
    ? 'RULE-SET,oisd_big,🚫 Реклама'
    : 'RULE-SET,oisd_small,🚫 Реклама';
  const rules = [];

  if (isExp) {
    rules.push('IP-CIDR6,::/0,REJECT-DROP,no-resolve');
  }

  rules.push(
    // 1. Локальные сети и базовые порты/процессы
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
    'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve',
    'AND,((NETWORK,tcp),(DST-PORT,22)),DIRECT',
    'PROCESS-NAME,ssh,DIRECT',

    // 2. Пользовательские кастомные правила (наивысший приоритет!)
    'RULE-SET,my-rules,📋 My Rules',

    // 3. Торренты, игры и локальные приложения
    'RULE-SET,torrent-clients,DIRECT',
    'PROCESS-NAME-REGEX,(?i).*torrent.*,DIRECT',
    'RULE-SET,games-direct,🎮 Игры (DIRECT)',
    'RULE-SET,ru_apps,DIRECT',

    // 4. Реклама
    adblockRule,

    // 4. Целевые сервисы (домены и процессы)
    'RULE-SET,geosite-youtube,▶️ YouTube',
    'RULE-SET,discord_vc,💬 Discord',
    'OR,((RULE-SET,geosite-discord),(PROCESS-NAME,Discord.exe)),💬 Discord',
    'PROCESS-NAME,com.instagram.android,📸 Instagram & Threads',
    'PROCESS-NAME,com.instagram.barcelona,📸 Instagram & Threads',
    'OR,((RULE-SET,geosite-instagram),(DOMAIN-SUFFIX,cdninstagram.com),(DOMAIN-SUFFIX,fbcdn.net),(DOMAIN-SUFFIX,fbsbx.com),(DOMAIN-SUFFIX,instagram.com),(DOMAIN-SUFFIX,threads.net),(DOMAIN-SUFFIX,graph.instagram.com),(DOMAIN-KEYWORD,instagram)),📸 Instagram & Threads',
    'RULE-SET,whatsapp-domains,📞 WhatsApp',
    'OR,((RULE-SET,geosite-facebook),(RULE-SET,geosite-meta),(DOMAIN-SUFFIX,graph.facebook.com)),👥 Facebook',
    'RULE-SET,telegram-domains,➤ Telegram',
    'PROCESS-NAME-REGEX,(?i).*ayugram.*,➤ Telegram',
    'PROCESS-NAME-REGEX,(?i).*telegram.*,➤ Telegram',
    'PROCESS-NAME,org.telegram.messenger,➤ Telegram',
    'RULE-SET,geosite-tiktok,🎵 TikTok',
    'RULE-SET,geosite-soundcloud,🎵 Spotify / SoundCloud',
    'RULE-SET,geosite-spotify,🎵 Spotify / SoundCloud',
    'OR,((RULE-SET,geosite-openai),(RULE-SET,google-gemini),(RULE-SET,geosite-anthropic),(DOMAIN-SUFFIX,grok.com),(DOMAIN-SUFFIX,x.ai),(DOMAIN-SUFFIX,appcenter.ms),(DOMAIN-SUFFIX,copilot.microsoft.com),(PROCESS-NAME-REGEX,(?i).*(chatgpt|claude|copilot|gemini|cursor|windsurf|cline|antigravity|opencode).*),(PROCESS-NAME,opencode),(PROCESS-NAME,com.openai.chatgpt),(PROCESS-NAME,com.anthropic.claude),(PROCESS-NAME,com.microsoft.copilot),(PROCESS-NAME,ai.perplexity.app.android)),🤖 AI (Нейронки)',
    'RULE-SET,geosite-supercell,👾 Brawl Stars',
    'RULE-SET,category-porn,🔞 18+',
    'RULE-SET,torrent-trackers,🌍 Зарубежный сервер',
    'RULE-SET,geosite-google,🔎 Google',

    // 5. Заблокированные домены РФ (должны идти ДО безусловных .ru)
    'RULE-SET,ru-bundle,🚫 Заблокированные сайты (RU)',
    'RULE-SET,ru-blocked,🚫 Заблокированные сайты (RU)',

    // 6. Прямой RU-трафик по доменным зонам
    'DOMAIN-SUFFIX,ru,DIRECT',
    'DOMAIN-SUFFIX,xn--p1ai,DIRECT',
    'DOMAIN-SUFFIX,su,DIRECT',

    // 7. IP-правила (в самом низу перед MATCH)
    'RULE-SET,discord_voiceips,💬 Discord,no-resolve',
    'RULE-SET,telegram-ips,➤ Telegram,no-resolve',
    'RULE-SET,facebook-ips,📞 WhatsApp,no-resolve',
    'RULE-SET,google-geoip,🔎 Google,no-resolve',
    'GEOIP,RU,DIRECT',
    'IP-CIDR,151.101.0.0/16,🚫 Заблокированные сайты (RU)',
    'RULE-SET,rknasnblock,🚫 Заблокированные сайты (RU)',

    // 8. Финальный фоллбэк
    'MATCH,🌐 Остальной трафик'
  );

  return rules;
}

// Generate the complete Mihomo config template for a user
function generateConfig(userName, ruProviderUrl, foreignProviderUrl, excludePackages = [], options = {}) {
  const isExp = Boolean(options.experimental);
  return {
    mode: 'rule',
    ipv6: isExp,
    'log-level': 'info',
    'allow-lan': false,
    'unified-delay': true,
    'tcp-concurrent': true,

    proxies: [
      { name: 'Без VPN (напрямую)', type: 'direct', udp: true },
      { name: 'Блокировать', type: 'reject' }
    ],

    dns: buildDns(),
    tun: buildTun(excludePackages, options),
    sniffer: buildSniffer(),
    'proxy-providers': buildProxyProviders(ruProviderUrl, foreignProviderUrl),
    'proxy-groups': buildProxyGroups(options),
    'rule-providers': buildRuleProviders(options),
    rules: buildRules(options)
  };
}

// Read every file in a user's ru/ or foreign/ dir and collect proxies:
// share links are parsed line-by-line, multi-line formats (raw WG/AWG
// .conf, Amnezia JSON) are parsed as a whole file.
async function collectProxiesFromDir(dir) {
  const proxies = [];
  if (!fs.existsSync(dir)) return proxies;
  for (const f of fs.readdirSync(dir).sort()) {
    const content = fs.readFileSync(path.join(dir, f), 'utf-8');
    const baseName = f.replace(/\.[^/.]+$/, '');

    for (const line of content.split('\n')) {
      asProxyList(await parseProxy(line, baseName), baseName).forEach(p => proxies.push(p));
    }

    if (content.includes('[Interface]') || content.trim().startsWith('{')) {
      asProxyList(await parseProxy(content, baseName), baseName).forEach(p => proxies.push(p));
    }
  }
  return proxies;
}

const BUILD_MODE_FILE = path.join(DATA_DIR, '.build-mode.json');
const TEST_USER = process.env.TEST_USER || 'Me';

function getStoredBuildMode() {
  if (fs.existsSync(BUILD_MODE_FILE)) {
    try {
      const data = JSON.parse(fs.readFileSync(BUILD_MODE_FILE, 'utf8'));
      if (data && data.mode) return data.mode;
    } catch {
      // ignore
    }
  }
  return 'stable';
}

function setStoredBuildMode(mode) {
  try {
    fs.mkdirSync(path.dirname(BUILD_MODE_FILE), { recursive: true });
    fs.writeFileSync(BUILD_MODE_FILE, JSON.stringify({ mode, updatedAt: new Date().toISOString() }, null, 2), { mode: 0o600 });
  } catch (e) {
    console.warn(`[warn] failed to save build mode: ${e.message}`);
  }
}

function isTestTarget(user, allUsers) {
  if (user === TEST_USER) return true;
  if (!allUsers.includes(TEST_USER) && (process.env.NODE_ENV === 'test' || process.env.CI) && user === allUsers[0]) {
    return true;
  }
  return false;
}

function isIosUser(userDir) {
  const customPath = path.join(userDir, 'custom.yaml');
  if (fs.existsSync(customPath)) {
    try {
      const cfg = yaml.load(fs.readFileSync(customPath, 'utf8'));
      if (cfg && (cfg.ios === true || cfg.is_ios === true || cfg.adblock === 'small')) {
        return true;
      }
    } catch {
      // ignore
    }
  }
  const markers = ['ios', 'is_ios', 'isIOS', 'isIOS=1', 'ios.txt', '.ios'];
  return markers.some(m => fs.existsSync(path.join(userDir, m)));
}

const DEFAULT_ADBLOCK = process.env.DEFAULT_ADBLOCK || 'small';

function getAdblockPreference(userDir, isIos) {
  if (isIos) return 'small';
  const customPath = path.join(userDir, 'custom.yaml');
  if (fs.existsSync(customPath)) {
    try {
      const cfg = yaml.load(fs.readFileSync(customPath, 'utf8'));
      if (cfg && cfg.adblock) return String(cfg.adblock).toLowerCase();
    } catch {
      // ignore
    }
  }
  const markers = ['big', 'oisd_big'];
  if (markers.some(m => fs.existsSync(path.join(userDir, m)))) return 'big';
  return DEFAULT_ADBLOCK;
}

function parseUserTimer(userDir) {
  const timerFile = path.join(userDir, 'timer.txt');
  const customFile = path.join(userDir, 'custom.yaml');
  let rawTimer = null;
  let rawTraffic = null;

  if (fs.existsSync(timerFile)) {
    rawTimer = fs.readFileSync(timerFile, 'utf8').trim();
  } else if (fs.existsSync(customFile)) {
    try {
      const cfg = yaml.load(fs.readFileSync(customFile, 'utf8'));
      if (cfg && (cfg.timer || cfg.expire || cfg.plan)) {
        rawTimer = String(cfg.timer || cfg.expire || cfg.plan).trim();
      }
      if (cfg && (cfg.traffic || cfg.total)) {
        rawTraffic = String(cfg.traffic || cfg.total).trim();
      }
    } catch {
      // ignore
    }
  }

  if (!rawTimer && !rawTraffic) {
    return null;
  }

  let totalBytes = 1099511627776; // default 1 TB
  if (rawTraffic) {
    const m = String(rawTraffic).match(/^(\d+(?:\.\d+)?)\s*(tb|t|gb|g|mb|m)?$/i);
    if (m) {
      const val = parseFloat(m[1]);
      const unit = (m[2] || 'gb').toLowerCase();
      if (unit.startsWith('t')) totalBytes = Math.round(val * 1024 * 1024 * 1024 * 1024);
      else if (unit.startsWith('g')) totalBytes = Math.round(val * 1024 * 1024 * 1024);
      else if (unit.startsWith('m')) totalBytes = Math.round(val * 1024 * 1024);
    }
  }

  let expireSeconds = 1893456000; // default 2030-01-01 (unlimited)
  if (rawTimer) {
    const parts = rawTimer.split(/\s+/);
    for (const part of parts) {
      const trfMatch = part.match(/^(\d+(?:\.\d+)?)(tb|t|gb|g|mb|m)$/i);
      if (trfMatch && !rawTraffic) {
        const val = parseFloat(trfMatch[1]);
        const unit = trfMatch[2].toLowerCase();
        if (unit.startsWith('t')) totalBytes = Math.round(val * 1024 * 1024 * 1024 * 1024);
        else if (unit.startsWith('g')) totalBytes = Math.round(val * 1024 * 1024 * 1024);
        else if (unit.startsWith('m')) totalBytes = Math.round(val * 1024 * 1024);
        continue;
      }

      const durMatch = part.match(/^(\d+)([dhmy])$/i);
      if (durMatch) {
        const count = parseInt(durMatch[1], 10);
        const unit = durMatch[2].toLowerCase();
        let seconds = 0;
        if (unit === 'h') seconds = count * 3600;
        else if (unit === 'd') seconds = count * 86400;
        else if (unit === 'm') seconds = count * 30 * 86400;
        else if (unit === 'y') seconds = count * 365 * 86400;

        const startedFile = path.join(userDir, '.started_at');
        let startedAt;
        if (fs.existsSync(startedFile)) {
          startedAt = parseInt(fs.readFileSync(startedFile, 'utf8').trim(), 10);
          if (isNaN(startedAt)) startedAt = Math.floor(Date.now() / 1000);
        } else {
          startedAt = Math.floor(Date.now() / 1000);
          fs.writeFileSync(startedFile, String(startedAt), { mode: 0o600 });
        }
        expireSeconds = startedAt + seconds;
        continue;
      }

      if (/^\d{4}-\d{2}-\d{2}/.test(part)) {
        const d = new Date(part);
        if (!isNaN(d.getTime())) {
          expireSeconds = Math.floor(d.getTime() / 1000);
        }
      }
    }
  }

  return `upload=0; download=0; total=${totalBytes}; expire=${expireSeconds}`;
}

function applyCustomConfig(baseConfig, userDir, user) {
  const masterConfig = JSON.parse(JSON.stringify(baseConfig));
  const customPath = path.join(userDir, 'custom.yaml');
  if (!fs.existsSync(customPath)) return masterConfig;

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
          // Сливаем rule-providers по имени
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
  return masterConfig;
}

// Process all users in the data directory
async function buildAll(overrideArg) {
  if (!fs.existsSync(DATA_DIR)) {
    console.log(`Directory ${DATA_DIR} does not exist. Created it.`);
    fs.mkdirSync(DATA_DIR, { recursive: true });
    return;
  }

  const rawArg = (overrideArg !== undefined ? overrideArg : (process.argv[2] || '')).toLowerCase().trim();
  let mode = getStoredBuildMode();

  if (rawArg === 'test') {
    mode = 'test';
    setStoredBuildMode('test');
    console.log('[mode] Build mode switched to: TEST (test profile gets experimental config)');
  } else if (rawArg === 'revert') {
    mode = 'stable';
    setStoredBuildMode('stable');
    console.log('[mode] Build mode switched to: REVERT/STABLE (all profiles reverted to stable config)');
  } else if (rawArg === 'promote') {
    mode = 'promoted';
    setStoredBuildMode('promoted');
    console.log('[mode] Build mode switched to: PROMOTED (all profiles promoted to experimental config)');
  } else {
    console.log(`[mode] Running in active build mode: ${mode.toUpperCase()}`);
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

  let usersToProcess = users;
  if (rawArg === 'test') {
    const targets = users.filter(u => isTestTarget(u, users));
    if (targets.length > 0) {
      usersToProcess = targets;
      console.log(`[info] Test mode: rebuilding ONLY test user(s): ${usersToProcess.join(', ')}`);
    } else {
      console.warn(`[warn] test target '${TEST_USER}' not found in data/. Available: ${users.join(', ')}`);
    }
  }

  const subInfoMap = {};

  for (const user of usersToProcess) {
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
      fs.writeFileSync(tokenFile, token, { mode: 0o600 });
      console.log(`[Info] Generated new secure token for user: ${user}`);
    }

    let ruProxies = await collectProxiesFromDir(ruDir);
    let foreignProxies = await collectProxiesFromDir(foreignDir);

    // Отключаем remote-dns-resolve и убираем 172.x DNS для всех Wireguard нод (RU и foreign),
    // чтобы туннели не зависали на недоступных докер-DNS и использовали централизованный DNS Mihomo.
    const sanitizeWireGuard = p => {
      if (p && p.type === 'wireguard') {
        delete p['remote-dns-resolve'];
        if (p.dns && Array.isArray(p.dns)) {
          p.dns = p.dns.filter(d => !/^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(d));
          if (p.dns.length === 0) delete p.dns;
        }
      }
      return p;
    };

    ruProxies = ruProxies.map(sanitizeWireGuard).filter(isValidProxy);
    foreignProxies = foreignProxies.map(sanitizeWireGuard).filter(isValidProxy);

    const getProtocolRank = p => {
      const type = String(p.type || '').toLowerCase();
      if (type === 'hysteria2' || type === 'hysteria') return 30;
      if (type === 'wireguard') return 20;
      if (type === 'vless') return 10;
      return 0;
    };

    const sortProxies = (a, b) => {
      const a10g = a.name.includes('10гбит') || a.name.includes('10G') || a.name.includes('10gbit');
      const b10g = b.name.includes('10гбит') || b.name.includes('10G') || b.name.includes('10gbit');
      if (a10g && !b10g) return -1;
      if (!a10g && b10g) return 1;
      const aRank = getProtocolRank(a);
      const bRank = getProtocolRank(b);
      if (aRank !== bRank) return bRank - aRank;
      return a.name.localeCompare(b.name);
    };

    // Deduplicate by endpoint (type:server:port), then disambiguate duplicate names
    const deduplicateProxies = list => {
      const seen = new Set();
      const unique = [];
      for (const p of list) {
        const key = `${p.type}:${p.server}:${p.port}`;
        if (seen.has(key)) continue;
        seen.add(key);
        unique.push(p);
      }
      const nameCounts = new Map();
      for (const p of unique) {
        const base = p.name || 'proxy';
        const count = (nameCounts.get(base) || 0) + 1;
        nameCounts.set(base, count);
        if (count > 1) {
          p.name = `${base}-${count}`;
        }
      }
      return unique.sort(sortProxies);
    };

    ruProxies = deduplicateProxies(ruProxies);
    foreignProxies = deduplicateProxies(foreignProxies);

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

    const isTest = isTestTarget(user, users);
    let isUserExp = false;
    if (mode === 'promoted') {
      isUserExp = true;
    } else if (mode === 'test') {
      isUserExp = isTest;
    }

    const isIos = isIosUser(userDir);
    const userPackages = isIos ? [] : ruPackages;
    const adblockMode = getAdblockPreference(userDir, isIos);
    const userOptions = { experimental: isUserExp, ios: isIos, adblock: adblockMode };

    // Write Master Config
    const rawMaster = generateConfig(
      user,
      `${BASE_URL}/providers/${token}_ru.yaml`,
      `${BASE_URL}/providers/${token}_foreign.yaml`,
      userPackages,
      userOptions
    );
    rawMaster['profile-name'] = process.env.PROFILE_NAME || 'Subscription Manager';
    const masterConfig = applyCustomConfig(rawMaster, userDir, user);
    fs.writeFileSync(configPath, yaml.dump(masterConfig, { indent: 2, lineWidth: -1 }));

    const subInfo = parseUserTimer(userDir);
    if (subInfo) {
      subInfoMap[`~*/configs/${token}$`] = subInfo;
      if (isTest) {
        subInfoMap[`~*/configs/${token}_stable$`] = subInfo;
      }
    }

    if (isTest) {
      // Для тестера генерируем стабильную версию (${token}_stable) как подушку безопасности
      const rawStable = generateConfig(
        user,
        `${BASE_URL}/providers/${token}_ru.yaml`,
        `${BASE_URL}/providers/${token}_foreign.yaml`,
        userPackages,
        { experimental: false, ios: isIos, adblock: adblockMode }
      );
      rawStable['profile-name'] = `${process.env.PROFILE_NAME || 'Subscription Manager'} (Stable)`;
      const stableConfig = applyCustomConfig(rawStable, userDir, user);
      const stableConfigPath = path.join(CONFIGS_DIR, `${token}_stable`);
      fs.writeFileSync(stableConfigPath, yaml.dump(stableConfig, { indent: 2, lineWidth: -1 }));

      console.log(`[Success] Generated configs for TEST user: ${user}${isIos ? ' [iOS]' : ''} [adblock: ${adblockMode}]`);
      console.log(`  -> Main Link:   ${BASE_URL}/configs/${token} [${isUserExp ? 'EXPERIMENTAL' : 'STABLE'}]`);
      console.log(`  -> Stable Link: ${BASE_URL}/configs/${token}_stable [STABLE FALLBACK]`);
    } else {
      console.log(`[Success] Generated configs for user: ${user}${isIos ? ' [iOS]' : ''} [adblock: ${adblockMode}]`);
      console.log(`  -> Subscription Link: ${BASE_URL}/configs/${token} [${isUserExp ? 'EXPERIMENTAL' : 'STABLE'}]`);
    }
  }

  const subInfoMapPath = path.join(PUBLIC_DIR, '.sub_info.map');
  let finalSubInfo = {};
  if (rawArg === 'test' && fs.existsSync(subInfoMapPath)) {
    for (const line of fs.readFileSync(subInfoMapPath, 'utf8').split('\n')) {
      const m = line.trim().match(/^(\S+)\s+"([^"]+)";/);
      if (m) finalSubInfo[m[1]] = m[2];
    }
  }
  Object.assign(finalSubInfo, subInfoMap);
  const mapLines = Object.entries(finalSubInfo).map(([k, v]) => `${k} "${v}";`);
  fs.writeFileSync(subInfoMapPath, mapLines.length > 0 ? mapLines.join('\n') + '\n' : '# subscription map\n', 'utf8');

  const templateHtml = path.join(__dirname, '..', 'templates', 'sub.html');
  const targetHtml = path.join(PUBLIC_DIR, 'sub.html');
  if (fs.existsSync(templateHtml)) {
    fs.copyFileSync(templateHtml, targetHtml);
  }
}

module.exports = {
  buildDns,
  buildTun,
  buildSniffer,
  buildProxyProviders,
  buildProxyGroups,
  buildRuleProviders,
  buildRules,
  generateConfig,
  getStoredBuildMode,
  setStoredBuildMode,
  isIosUser,
  getAdblockPreference,
  parseUserTimer,
  buildAll
};

if (require.main === module) {
  buildAll().catch(console.error);
}
