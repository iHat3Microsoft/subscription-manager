'use strict';
const assert = require('assert');
const path = require('path');
const fs = require('fs');
const build = require('../src/build');

async function testDns() {
  const dns = build.buildDns();
  assert.strictEqual(dns.enable, true);
  assert.strictEqual(dns.ipv6, false);
  assert.strictEqual(dns['prefer-ipv4'], undefined, 'prefer-ipv4 must not exist in dns');
  assert.strictEqual(dns['cache-algorithm'], 'arc', 'cache-algorithm must be arc');
  assert.strictEqual(dns['respect-rules'], true, 'respect-rules must be true');

  assert.ok(Array.isArray(dns['proxy-server-nameserver']), 'proxy-server-nameserver must be an array');
  assert.ok(dns['proxy-server-nameserver'].some(s => s.includes('yandex')), 'proxy-server-nameserver must include yandex');
  assert.ok(dns['proxy-server-nameserver'].every(s => s.includes('disable-ipv6=true')), 'proxy-server-nameserver must have disable-ipv6=true');
  assert.ok(dns['direct-nameserver'].every(s => s.includes('disable-ipv6=true')), 'direct-nameserver must have disable-ipv6=true');

  assert.ok(dns.nameserver.every(ns => ns.includes('#🌍 Зарубежный сервер')), 'nameserver DoH must route to proxy group via # suffix');
  assert.ok(dns.nameserver.some(ns => ns.includes('1.1.1.1')), 'nameserver must include 1.1.1.1');
  assert.ok(dns.nameserver.some(ns => ns.includes('8.8.8.8')), 'nameserver must include 8.8.8.8');

  assert.ok(dns['fake-ip-filter'].includes('+.msftncsi.com'), 'fake-ip-filter must include msftncsi');
  assert.ok(dns['fake-ip-filter'].includes('+.stun.*'), 'fake-ip-filter must include stun');

  assert.ok(dns['nameserver-policy']['geosite:category-ru'], 'nameserver-policy must include geosite:category-ru');
  assert.ok(dns['nameserver-policy']['+.ru'], 'nameserver-policy must include +.ru');
  assert.ok(dns['nameserver-policy']['+.xn--p1ai'], 'nameserver-policy must include +.xn--p1ai');

  console.log('ok - DNS configuration verified');
}

async function testTun() {
  const stableTun = build.buildTun([], { experimental: false });
  assert.strictEqual(stableTun.stack, undefined, 'stack must be omitted for backward compatibility');
  assert.strictEqual(stableTun['inet6-address'], undefined);
  assert.ok(stableTun['route-exclude-address'].includes('::/127'));
  assert.ok(stableTun['route-exclude-address'].includes('ff00::/8'));

  const expTun = build.buildTun([], { experimental: true });
  assert.strictEqual(expTun.stack, undefined, 'stack must be omitted for backward compatibility');
  assert.deepStrictEqual(expTun['inet6-address'], ['fdfe:dcba:9876::1/126']);
  assert.strictEqual(expTun['route-exclude-address'].includes('::/127'), false);
  assert.strictEqual(expTun['route-exclude-address'].includes('ff00::/8'), false);
  assert.ok(expTun['route-exclude-address'].includes('fc00::/7'));

  console.log('ok - TUN stack omission and IPv6 sinkhole verified');
}

async function testSniffer() {
  const sniffer = build.buildSniffer();
  assert.strictEqual(sniffer.enable, true);
  assert.strictEqual(sniffer.sniff.QUIC, undefined, 'QUIC sniffing must be removed (no REJECT-QUIC rule)');
  assert.ok(sniffer.sniff.TLS, 'TLS sniffing must be present');
  assert.ok(Array.isArray(sniffer['skip-domain']), 'skip-domain must be an array');
  assert.ok(sniffer['skip-domain'].includes('Mijia Cloud'), 'skip-domain must include Mijia Cloud');
  assert.ok(sniffer['skip-domain'].includes('+.push.apple.com'), 'skip-domain must include +.push.apple.com');
  assert.ok(sniffer['skip-domain'].includes('+.apple.com'), 'skip-domain must include +.apple.com');
  assert.ok(sniffer['skip-domain'].includes('+.3gppnetwork.org'), 'skip-domain must include +.3gppnetwork.org');
  assert.ok(sniffer['skip-domain'].includes('+.msftconnecttest.com'), 'skip-domain must include +.msftconnecttest.com');
  console.log('ok - Sniffer verified (no QUIC, skip-domain present)');
}

async function testProxyGroups() {
  const stableGroups = build.buildProxyGroups({ experimental: false });
  assert.strictEqual(stableGroups.some(g => g.name === '⚡ Параллельно'), false);
  const stableForeign = stableGroups.find(g => g.name === '🌍 Зарубежный сервер');
  assert.deepStrictEqual(stableForeign.proxies, ['♻️ Автовыбор']);

  const expGroups = build.buildProxyGroups({ experimental: true });
  const lbGroup = expGroups.find(g => g.name === '⚡ Параллельно');
  assert.ok(lbGroup, 'load-balance group must exist in experimental mode');
  assert.strictEqual(lbGroup.type, 'load-balance');
  assert.strictEqual(lbGroup.strategy, 'sticky-sessions');

  const expForeign = expGroups.find(g => g.name === '🌍 Зарубежный сервер');
  assert.ok(expForeign.proxies.includes('⚡ Параллельно'));
  assert.strictEqual(expForeign.proxies[0], '♻️ Автовыбор', 'Fallback must be default in experimental mode');
  assert.strictEqual(expForeign.proxies[1], '⚡ Параллельно', 'Balancing must be second in experimental mode');

  const autoForeign = stableGroups.find(g => g.name === '♻️ Автовыбор');
  assert.strictEqual(autoForeign.timeout, 3000);
  assert.strictEqual(autoForeign['max-failed-times'], 1);

  const aiGroup = stableGroups.find(g => g.name === '🤖 AI (Нейронки)');
  assert.deepStrictEqual(aiGroup.proxies, ['♻️ Автовыбор', '🌍 Зарубежный сервер']);

  const adGroup = stableGroups.find(g => g.name === 'Реклама');
  assert.ok(adGroup, 'Adblock group must exist');
  assert.deepStrictEqual(adGroup.proxies, ['🚫 Блокировать', 'Без VPN (напрямую)', '🌍 Зарубежный сервер']);
  assert.strictEqual(adGroup.use, undefined, 'Adblock must not list individual servers in use: [...]');

  const googleGroup = stableGroups.find(g => g.name === '🔎 Google');
  assert.deepStrictEqual(googleGroup.proxies, ['Без VPN (напрямую)', '♻️ Автовыбор', '🌍 Зарубежный сервер']);

  const musicGroup = stableGroups.find(g => g.name === '🎵 Spotify / SoundCloud');
  assert.ok(musicGroup, 'Spotify / SoundCloud group must exist');
  assert.strictEqual(musicGroup.hidden, undefined, 'Spotify / SoundCloud group must be visible');
  assert.deepStrictEqual(musicGroup.proxies, ['♻️ Сначала РФ', '🌍 Зарубежный сервер', 'Без VPN (напрямую)']);

  const abroadGroup = stableGroups.find(g => g.name === '🇷🇺 Российский трафик');
  assert.ok(abroadGroup, 'Российский трафик must exist');
  assert.strictEqual(abroadGroup.hidden, true, 'Российский трафик must be hidden by default');
  assert.deepStrictEqual(abroadGroup.proxies, ['Без VPN (напрямую)', '🇷🇺 Российские серверы']);

  console.log('ok - Proxy groups and sticky-sessions load-balance verified');
}

async function testRuleProviders() {
  const defaultProviders = build.buildRuleProviders();
  assert.strictEqual(defaultProviders.quic, undefined, 'inline quic provider must be removed');
  assert.ok(defaultProviders.oisd_small, 'default must use oisd_small');
  assert.strictEqual(defaultProviders.oisd_big, undefined);

  const bigProviders = build.buildRuleProviders({ adblock: 'big' });
  assert.ok(bigProviders.oisd_big, 'adblock: big must use oisd_big');
  assert.strictEqual(bigProviders.oisd_small, undefined);

  assert.strictEqual(defaultProviders['ru-blocked'].behavior, 'domain');
  assert.strictEqual(defaultProviders['ru-blocked'].format, 'text');
  assert.strictEqual(defaultProviders['ru-blocked'].path, './rule-sets/ru-blocked.txt');

  assert.strictEqual(defaultProviders['geosite-tiktok'].format, 'mrs');
  assert.strictEqual(defaultProviders['geosite-tiktok'].path, './rule-sets/tiktok.mrs');
  assert.strictEqual(defaultProviders['geosite-soundcloud'].format, 'mrs');
  assert.strictEqual(defaultProviders['geosite-spotify'].format, 'mrs');

  console.log('ok - Rule providers verified (default oisd_small, opt-in oisd_big, ru-blocked text format, geosite-tiktok mrs)');
}

async function testRules() {
  const stableRules = build.buildRules({ experimental: false });
  assert.strictEqual(stableRules.some(r => r.startsWith('IP-CIDR6,::/0')), false);
  assert.strictEqual(stableRules.some(r => r.includes('quic')), false);
  assert.ok(stableRules.includes('RULE-SET,oisd_small,Реклама'), 'default must use oisd_small');

  const bigRules = build.buildRules({ adblock: 'big' });
  assert.ok(bigRules.includes('RULE-SET,oisd_big,Реклама'), 'adblock: big must use oisd_big');

  const expRules = build.buildRules({ experimental: true });
  assert.strictEqual(expRules[0], 'IP-CIDR6,::/0,REJECT-DROP,no-resolve');

  // Verify hierarchy
  const myRulesIdx = stableRules.findIndex(r => r.includes('my-rules'));
  const ruBundleIdx = stableRules.findIndex(r => r.includes('ru-bundle'));
  const ruBlockedIdx = stableRules.findIndex(r => r.includes('ru-blocked'));
  const ruDirectIdx = stableRules.findIndex(r => r === 'DOMAIN-SUFFIX,ru,🇷🇺 Российский трафик');
  const xnDirectIdx = stableRules.findIndex(r => r === 'DOMAIN-SUFFIX,xn--p1ai,🇷🇺 Российский трафик');
  const rknAsnIdx = stableRules.findIndex(r => r.includes('rknasnblock'));
  const matchIdx = stableRules.findIndex(r => r.startsWith('MATCH'));

  assert.ok(myRulesIdx < stableRules.findIndex(r => r.includes('games-direct')), 'my-rules must be above games-direct');
  assert.ok(myRulesIdx < ruBundleIdx, 'my-rules must be higher priority than ru-bundle');
  assert.ok(ruBundleIdx < ruDirectIdx, 'ru-bundle must be checked BEFORE DOMAIN-SUFFIX,ru');
  assert.ok(ruBlockedIdx < ruDirectIdx, 'ru-blocked must be checked BEFORE DOMAIN-SUFFIX,ru');
  assert.ok(xnDirectIdx > 0, 'DOMAIN-SUFFIX,xn--p1ai must exist');
  assert.strictEqual(stableRules.some(r => r.includes('DOMAIN-SUFFIX,рф')), false, 'Cyrillic .рф must be replaced with punycode');

  // IP rules at the bottom
  assert.ok(rknAsnIdx > ruDirectIdx, 'rknasnblock must be below domain rules');
  assert.ok(stableRules.includes('IP-CIDR,151.101.0.0/16,🚫 Заблокированные сайты (RU)'), 'Fastly CDN rule must be present');
  assert.strictEqual(stableRules.find(r => r.includes('rknasnblock')), 'RULE-SET,rknasnblock,🚫 Заблокированные сайты (RU)', 'rknasnblock must resolve unclassified CDN IPs');
  assert.ok(stableRules.find(r => r.startsWith('GEOIP,RU')).endsWith('no-resolve') || stableRules.find(r => r === 'GEOIP,RU,🇷🇺 Российский трафик'), 'GEOIP,RU must be near bottom');
  assert.strictEqual(matchIdx, stableRules.length - 1, 'MATCH must be the final rule');
  assert.strictEqual(stableRules.some(r => r.includes('IP-ASN')), false, 'IP-ASN must be removed to avoid downloading GeoASN.dat');

  // Meta & AI rules
  const instaRule = stableRules.find(r => r.includes('📸 Instagram & Threads') && r.startsWith('OR,'));
  assert.strictEqual(instaRule.includes('geosite-meta'), false, 'geosite-meta must be removed from Instagram');
  const fbRule = stableRules.find(r => r.includes('👥 Facebook'));
  assert.ok(fbRule.includes('geosite-meta'), 'Facebook must use geosite-meta');

  const aiRule = stableRules.find(r => r.includes('🤖 AI (Нейронки)'));
  assert.strictEqual(aiRule.includes('DOMAIN-KEYWORD,grok'), false, 'broad grok keyword must be removed');
  assert.strictEqual(aiRule.includes('DOMAIN-KEYWORD,copilot'), false, 'broad copilot keyword must be removed');
  assert.ok(aiRule.includes('DOMAIN-SUFFIX,grok.com'), 'exact grok.com suffix must remain');

  assert.ok(stableRules.includes('RULE-SET,category-porn,🔞 18+'));
  assert.ok(stableRules.includes('RULE-SET,geosite-soundcloud,🎵 Spotify / SoundCloud'));
  assert.ok(stableRules.includes('RULE-SET,geosite-spotify,🎵 Spotify / SoundCloud'));

  console.log('ok - Rules ordering, no-resolve and cleanups verified');
}

async function testGenerateConfig() {
  const stable = build.generateConfig('User1', 'http://ru', 'http://foreign', [], { experimental: false });
  assert.strictEqual(stable.ipv6, false);
  assert.strictEqual(stable.tun.stack, undefined);
  assert.ok(stable.profile, 'profile section must exist');
  assert.strictEqual(stable.profile['store-selected'], true, 'profile.store-selected must be true');
  assert.strictEqual(stable.profile['store-fake-ip'], undefined, 'store-fake-ip must NOT be enabled (causes cache desync)');
  assert.ok(Array.isArray(stable.proxies), 'proxies must be an array');
  assert.ok(stable.proxies.some(p => p.name === 'Без VPN (напрямую)' && p.type === 'direct'), 'Без VPN (напрямую) direct proxy must exist');
  assert.ok(stable.proxies.some(p => p.name === '🚫 Блокировать' && p.type === 'reject'), '🚫 Блокировать reject proxy must exist');

  const exp = build.generateConfig('User1', 'http://ru', 'http://foreign', [], { experimental: true });
  assert.strictEqual(exp.ipv6, true);
  assert.strictEqual(exp.tun.stack, undefined);

  console.log('ok - generateConfig stable vs experimental verified');
}

async function testBuildMode() {
  const initialMode = build.getStoredBuildMode();

  build.setStoredBuildMode('test');
  assert.strictEqual(build.getStoredBuildMode(), 'test');

  build.setStoredBuildMode('promoted');
  assert.strictEqual(build.getStoredBuildMode(), 'promoted');

  build.setStoredBuildMode('stable');
  assert.strictEqual(build.getStoredBuildMode(), 'stable');

  // restore initial
  build.setStoredBuildMode(initialMode);
  console.log('ok - Build mode state persistence verified');
}

async function testIosDetection() {
  const tmpDir = path.join(__dirname, 'tmp_ios_test');
  fs.mkdirSync(tmpDir, { recursive: true });
  try {
    assert.strictEqual(build.isIosUser(tmpDir), false);

    fs.writeFileSync(path.join(tmpDir, 'ios'), '');
    assert.strictEqual(build.isIosUser(tmpDir), true);
    fs.unlinkSync(path.join(tmpDir, 'ios'));

    fs.writeFileSync(path.join(tmpDir, 'is_ios'), '');
    assert.strictEqual(build.isIosUser(tmpDir), true);
    fs.unlinkSync(path.join(tmpDir, 'is_ios'));

    fs.writeFileSync(path.join(tmpDir, 'isIOS'), '');
    assert.strictEqual(build.isIosUser(tmpDir), true);
    fs.unlinkSync(path.join(tmpDir, 'isIOS'));

    fs.writeFileSync(path.join(tmpDir, 'custom.yaml'), 'ios: true\n');
    assert.strictEqual(build.isIosUser(tmpDir), true);
    assert.strictEqual(build.getAdblockPreference(tmpDir, true), 'small');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
  console.log('ok - iOS user detection verified');
}

async function testUserTimer() {
  const tmpDir = path.join(__dirname, 'tmp-timer-test');
  fs.mkdirSync(tmpDir, { recursive: true });

  try {
    // 1. None
    assert.strictEqual(build.parseUserTimer(tmpDir), null);

    // 2. 7 days relative
    fs.writeFileSync(path.join(tmpDir, 'timer.txt'), '7d\n');
    const res7d = build.parseUserTimer(tmpDir);
    assert.ok(res7d.includes('total=1099511627776; expire='));
    const exp7d = parseInt(res7d.match(/expire=(\d+)/)[1], 10);
    const now = Math.floor(Date.now() / 1000);
    assert.ok(exp7d >= now + 6 * 86400 && exp7d <= now + 8 * 86400);

    // 3. 30d with 50GB
    fs.writeFileSync(path.join(tmpDir, 'timer.txt'), '30d 50GB\n');
    const res30d = build.parseUserTimer(tmpDir);
    assert.ok(res30d.includes('total=53687091200; expire='));

    // 4. Exact date
    fs.writeFileSync(path.join(tmpDir, 'timer.txt'), '2026-11-20\n');
    const resDate = build.parseUserTimer(tmpDir);
    const expDate = parseInt(resDate.match(/expire=(\d+)/)[1], 10);
    assert.strictEqual(expDate, Math.floor(new Date('2026-11-20').getTime() / 1000));

    // 5. custom.yaml
    fs.unlinkSync(path.join(tmpDir, 'timer.txt'));
    fs.writeFileSync(path.join(tmpDir, 'custom.yaml'), 'plan: 14d\ntraffic: 100GB\n');
    const resCustom = build.parseUserTimer(tmpDir);
    assert.ok(resCustom.includes('total=107374182400; expire='));
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
  console.log('ok - User timer & traffic limits verified');
}

async function main() {
  await testDns();
  await testTun();
  await testSniffer();
  await testProxyGroups();
  await testRuleProviders();
  await testRules();
  await testGenerateConfig();
  await testBuildMode();
  await testIosDetection();
  await testUserTimer();
  console.log('build: all assertions passed');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
