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

  assert.ok(dns.nameserver.every(ns => ns.includes('#🌍 Иностранные серверы')), 'nameserver DoH must route to proxy group via # suffix');
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
  assert.strictEqual(stableTun.stack, 'mixed');
  assert.strictEqual(stableTun['inet6-address'], undefined);
  assert.ok(stableTun['route-exclude-address'].includes('::/127'));
  assert.ok(stableTun['route-exclude-address'].includes('ff00::/8'));

  const expTun = build.buildTun([], { experimental: true });
  assert.strictEqual(expTun.stack, 'mips');
  assert.deepStrictEqual(expTun['inet6-address'], ['fdfe:dcba:9876::1/126']);
  assert.strictEqual(expTun['route-exclude-address'].includes('::/127'), false);
  assert.strictEqual(expTun['route-exclude-address'].includes('ff00::/8'), false);
  assert.ok(expTun['route-exclude-address'].includes('fc00::/7'));

  console.log('ok - TUN stack and IPv6 sinkhole verified');
}

async function testSniffer() {
  const sniffer = build.buildSniffer();
  assert.strictEqual(sniffer.enable, true);
  assert.ok(sniffer.sniff.QUIC, 'QUIC sniffing must be enabled');
  assert.deepStrictEqual(sniffer.sniff.QUIC.ports, [443, 8443]);
  console.log('ok - Sniffer QUIC verified');
}

async function testProxyGroups() {
  const stableGroups = build.buildProxyGroups({ experimental: false });
  assert.strictEqual(stableGroups.some(g => g.name === '⚖️ Балансировка (Иностранные)'), false);
  const stableForeign = stableGroups.find(g => g.name === '🌍 Иностранные серверы');
  assert.deepStrictEqual(stableForeign.proxies, ['♻️ Автовыбор (Иностранные)']);

  const expGroups = build.buildProxyGroups({ experimental: true });
  const lbGroup = expGroups.find(g => g.name === '⚖️ Балансировка (Иностранные)');
  assert.ok(lbGroup, 'load-balance group must exist in experimental mode');
  assert.strictEqual(lbGroup.type, 'load-balance');
  assert.strictEqual(lbGroup.strategy, 'sticky-sessions');

  const expForeign = expGroups.find(g => g.name === '🌍 Иностранные серверы');
  assert.ok(expForeign.proxies.includes('⚖️ Балансировка (Иностранные)'));

  const aiGroup = stableGroups.find(g => g.name === '🤖 AI (Нейронки)');
  assert.deepStrictEqual(aiGroup.proxies, ['♻️ Автовыбор (Иностранные)', '🌍 Иностранные серверы']);

  const googleGroup = stableGroups.find(g => g.name === '🔎 Google');
  assert.deepStrictEqual(googleGroup.proxies, ['DIRECT', '♻️ Автовыбор (Иностранные)', '🌍 Иностранные серверы']);

  console.log('ok - Proxy groups and sticky-sessions load-balance verified');
}

async function testRuleProviders() {
  const providers = build.buildRuleProviders();
  assert.strictEqual(providers.quic, undefined, 'inline quic provider must be removed');

  assert.strictEqual(providers['ru-blocked'].behavior, 'domain');
  assert.strictEqual(providers['ru-blocked'].format, 'text');
  assert.strictEqual(providers['ru-blocked'].path, './rule-sets/ru-blocked.txt');

  assert.strictEqual(providers['geosite-tiktok'].format, 'mrs');
  assert.strictEqual(providers['geosite-tiktok'].path, './rule-sets/tiktok.mrs');

  console.log('ok - Rule providers verified (ru-blocked text format, geosite-tiktok mrs)');
}

async function testRules() {
  const stableRules = build.buildRules({ experimental: false });
  assert.strictEqual(stableRules.some(r => r.startsWith('IP-CIDR6,::/0')), false);
  assert.strictEqual(stableRules.some(r => r.includes('quic')), false);

  const expRules = build.buildRules({ experimental: true });
  assert.strictEqual(expRules[0], 'IP-CIDR6,::/0,REJECT-DROP,no-resolve');

  // Verify hierarchy
  const myRulesIdx = stableRules.findIndex(r => r.includes('my-rules'));
  const ruBundleIdx = stableRules.findIndex(r => r.includes('ru-bundle'));
  const ruBlockedIdx = stableRules.findIndex(r => r.includes('ru-blocked'));
  const ruDirectIdx = stableRules.findIndex(r => r === 'DOMAIN-SUFFIX,ru,DIRECT');
  const xnDirectIdx = stableRules.findIndex(r => r === 'DOMAIN-SUFFIX,xn--p1ai,DIRECT');
  const rknAsnIdx = stableRules.findIndex(r => r.includes('rknasnblock'));
  const matchIdx = stableRules.findIndex(r => r.startsWith('MATCH'));

  assert.ok(myRulesIdx < ruBundleIdx, 'my-rules must be higher priority than ru-bundle');
  assert.ok(ruBundleIdx < ruDirectIdx, 'ru-bundle must be checked BEFORE DOMAIN-SUFFIX,ru,DIRECT');
  assert.ok(ruBlockedIdx < ruDirectIdx, 'ru-blocked must be checked BEFORE DOMAIN-SUFFIX,ru,DIRECT');
  assert.ok(xnDirectIdx > 0, 'DOMAIN-SUFFIX,xn--p1ai,DIRECT must exist');
  assert.strictEqual(stableRules.some(r => r.includes('DOMAIN-SUFFIX,рф')), false, 'Cyrillic .рф must be replaced with punycode');

  // IP rules at the bottom
  assert.ok(rknAsnIdx > ruDirectIdx, 'rknasnblock must be below domain rules');
  assert.strictEqual(stableRules.find(r => r.includes('rknasnblock')), 'RULE-SET,rknasnblock,🚫 Заблокированные сайты (RU)', 'rknasnblock must resolve unclassified CDN IPs');
  assert.ok(stableRules.find(r => r.startsWith('GEOIP,RU')).endsWith('no-resolve') || stableRules.find(r => r === 'GEOIP,RU,DIRECT'), 'GEOIP,RU must be near bottom');
  assert.strictEqual(matchIdx, stableRules.length - 1, 'MATCH must be the final rule');

  // Meta & AI rules
  const instaRule = stableRules.find(r => r.includes('📸 Instagram & Threads') && r.startsWith('OR,'));
  assert.strictEqual(instaRule.includes('geosite-meta'), false, 'geosite-meta must be removed from Instagram');
  const fbRule = stableRules.find(r => r.includes('👥 Facebook'));
  assert.ok(fbRule.includes('geosite-meta'), 'Facebook must use geosite-meta');

  const aiRule = stableRules.find(r => r.includes('🤖 AI (Нейронки)'));
  assert.strictEqual(aiRule.includes('DOMAIN-KEYWORD,grok'), false, 'broad grok keyword must be removed');
  assert.strictEqual(aiRule.includes('DOMAIN-KEYWORD,copilot'), false, 'broad copilot keyword must be removed');
  assert.ok(aiRule.includes('DOMAIN-SUFFIX,grok.com'), 'exact grok.com suffix must remain');

  console.log('ok - Rules ordering, no-resolve and cleanups verified');
}

async function testGenerateConfig() {
  const stable = build.generateConfig('User1', 'http://ru', 'http://foreign', [], { experimental: false });
  assert.strictEqual(stable.ipv6, false);
  assert.strictEqual(stable.tun.stack, 'mixed');

  const exp = build.generateConfig('User1', 'http://ru', 'http://foreign', [], { experimental: true });
  assert.strictEqual(exp.ipv6, true);
  assert.strictEqual(exp.tun.stack, 'mips');

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

async function main() {
  await testDns();
  await testTun();
  await testSniffer();
  await testProxyGroups();
  await testRuleProviders();
  await testRules();
  await testGenerateConfig();
  await testBuildMode();
  console.log('build: all assertions passed');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
