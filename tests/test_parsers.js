// Regression tests for src/parsers.js share-link/config parsing.
// Plain assert, no framework, no dependencies. Run: node tests/test_parsers.js
'use strict';
const assert = require('assert');
const parsers = require('../src/parsers');

async function main() {
  // --- vless: reality share link -------------------------------------------
  const vless = await parsers.parseProxyUrl(
    'vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443' +
    '?encryption=none&security=reality&sni=www.example.com&fp=chrome' +
    '&pbk=xR8hP2cQmZ4vB6nM1sK9wE7tY3uJ5aD0fL8gH2iO4qR&sid=ab12ab12' +
    '&type=tcp&flow=xtls-rprx-vision#NL-10gbit'
  );
  assert.strictEqual(vless.type, 'vless');
  assert.strictEqual(vless.name, 'NL-10gbit');
  assert.strictEqual(vless.server, 'example.com');
  assert.strictEqual(vless.port, 443);
  assert.strictEqual(vless.uuid, 'b831381d-6324-4d53-ad4f-8cda48b30811');
  assert.strictEqual(vless.tls, true);
  assert.strictEqual(vless.flow, 'xtls-rprx-vision');
  assert.strictEqual(vless['reality-opts']['public-key'], 'xR8hP2cQmZ4vB6nM1sK9wE7tY3uJ5aD0fL8gH2iO4qR');
  assert.strictEqual(vless['reality-opts']['short-id'], 'ab12ab12');
  assert.strictEqual(vless.servername, 'www.example.com');

  // --- vmess: legacy base64 JSON -------------------------------------------
  const vmessB64 = Buffer.from(JSON.stringify({
    v: '2', ps: 'Test-VMESS', add: 'vmess.example.com', port: '443',
    id: '12345678-9abc-4def-8123-456789abcde0', aid: '0',
    net: 'tcp', type: 'none', tls: 'tls', sni: 's.example.com'
  })).toString('base64');
  const vmess = await parsers.parseProxyUrl(`vmess://${vmessB64}`);
  assert.strictEqual(vmess.type, 'vmess');
  assert.strictEqual(vmess.name, 'Test-VMESS');
  assert.strictEqual(vmess.server, 'vmess.example.com');
  assert.strictEqual(vmess.cipher, 'auto');
  assert.strictEqual(vmess.alterId, 0);
  assert.strictEqual(vmess.tls, true);

  // --- trojan ----------------------------------------------------------------
  const trojan = await parsers.parseProxyUrl(
    'trojan://secretpw@tro.example.com:443?sni=t.example.com&type=ws&path=%2Fws#TR'
  );
  assert.strictEqual(trojan.type, 'trojan');
  assert.strictEqual(trojan.password, 'secretpw');
  assert.strictEqual(trojan.sni, 't.example.com');
  assert.strictEqual(trojan.network, 'ws');
  assert.strictEqual(trojan['ws-opts'].path, '/ws');

  // --- hysteria2 --------------------------------------------------------------
  const hy2 = await parsers.parseProxyUrl(
    'hy2://pw@hy.example.com:8443?sni=hy.example.com&insecure=1&obfs=salamander&obfs-password=ob1#HY'
  );
  assert.strictEqual(hy2.type, 'hysteria2');
  assert.strictEqual(hy2.password, 'pw');
  assert.strictEqual(hy2['skip-cert-verify'], true);
  assert.strictEqual(hy2.obfs, 'salamander');
  assert.strictEqual(hy2['obfs-password'], 'ob1');

  // --- tuic -------------------------------------------------------------------
  const tuic = await parsers.parseProxyUrl(
    'tuic://uuid-here:pass@tu.example.com:443?sni=tu.example.com&congestion_control=bbr&udp_relay_mode=native#TU'
  );
  assert.strictEqual(tuic.type, 'tuic');
  assert.strictEqual(tuic.uuid, 'uuid-here');
  assert.strictEqual(tuic.password, 'pass');
  assert.strictEqual(tuic['congestion-controller'], 'bbr');
  assert.strictEqual(tuic['udp-relay-mode'], 'native');

  // --- ss: standard formats ----------------------------------------------------
  // 1. Plain userinfo
  const ssPlain = parsers.parseSS('ss://chacha20-ietf-poly1305:mypassword@ss1.example.com:8443#SS-Plain');
  assert.strictEqual(ssPlain.type, 'ss');
  assert.strictEqual(ssPlain.name, 'SS-Plain');
  assert.strictEqual(ssPlain.cipher, 'chacha20-ietf-poly1305');
  assert.strictEqual(ssPlain.password, 'mypassword');
  assert.strictEqual(ssPlain.server, 'ss1.example.com');
  assert.strictEqual(ssPlain.port, 8443);
  assert.strictEqual(ssPlain.udp, true);

  // 2. Base64 userinfo
  const ssUserinfo = Buffer.from('aes-256-gcm:sspass').toString('base64');
  const ss = await parsers.parseProxyUrl(`ss://${ssUserinfo}@ss.example.com:8388#SS`);
  assert.strictEqual(ss.type, 'ss');
  assert.strictEqual(ss.name, 'SS');
  assert.strictEqual(ss.cipher, 'aes-256-gcm');
  assert.strictEqual(ss.password, 'sspass');
  assert.strictEqual(ss.server, 'ss.example.com');
  assert.strictEqual(ss.port, 8388);

  // 3. Full base64 host URL
  const ssFullB64Str = Buffer.from('aes-256-gcm:pass456@ss3.example.com:8388').toString('base64');
  const ssFullB64 = parsers.parseSS(`ss://${ssFullB64Str}#SS-FullB64`);
  assert.strictEqual(ssFullB64.type, 'ss');
  assert.strictEqual(ssFullB64.name, 'SS-FullB64');
  assert.strictEqual(ssFullB64.cipher, 'aes-256-gcm');
  assert.strictEqual(ssFullB64.password, 'pass456');
  assert.strictEqual(ssFullB64.server, 'ss3.example.com');
  assert.strictEqual(ssFullB64.port, 8388);

  // 4. Full base64 host URL with default name fallback (no tag hash)
  const ssFullB64NoTagStr = Buffer.from('aes-128-gcm:pass789@ss4.example.com:8388').toString('base64');
  const ssFullB64NoTag = parsers.parseSS(`ss://${ssFullB64NoTagStr}`);
  assert.strictEqual(ssFullB64NoTag.name, 'ss-ss4.example.com');
  assert.strictEqual(ssFullB64NoTag.server, 'ss4.example.com');

  // --- ss: query parameters & plugins -----------------------------------------
  // UDP over TCP (udp-over-tcp=true)
  const ssUot1 = parsers.parseSS('ss://chacha20-ietf-poly1305:mypassword@ss1.example.com:8443?udp-over-tcp=true#SS-Uot1');
  assert.strictEqual(ssUot1['udp-over-tcp'], true);

  // UDP over TCP (uot=1)
  const ssUot2 = parsers.parseSS('ss://chacha20-ietf-poly1305:mypassword@ss1.example.com:8443?uot=1#SS-Uot2');
  assert.strictEqual(ssUot2['udp-over-tcp'], true);

  // obfs plugin
  const ssObfs = parsers.parseSS(
    'ss://chacha20-ietf-poly1305:mypassword@ss1.example.com:8443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#SS-Obfs'
  );
  assert.strictEqual(ssObfs.plugin, 'obfs');
  assert.deepStrictEqual(ssObfs['plugin-opts'], {
    mode: 'http',
    host: 'example.com'
  });

  // v2ray-plugin
  const ssV2ray = parsers.parseSS(
    'ss://chacha20-ietf-poly1305:mypassword@ss1.example.com:8443?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3Dexample.com%3Bpath%3D%2Fws%3Btls#SS-V2Ray'
  );
  assert.strictEqual(ssV2ray.plugin, 'v2ray-plugin');
  assert.deepStrictEqual(ssV2ray['plugin-opts'], {
    mode: 'websocket',
    host: 'example.com',
    path: '/ws',
    tls: true
  });

  // --- raw WG .conf with Amnezia params -----------------------------------------
  const wgConf = [
    '[Interface]', 'PrivateKey = iK+xGy8bJmQ0zF3vN7sTqLpW2aD5cH8eR1uY6oB4nM0=',
    'Address = 10.0.0.2/32', 'DNS = 77.88.8.8', 'Jc = 4', 'Jmin = 40', 'Jmax = 70', 'S1 = 5',
    '', '[Peer]',
    'PublicKey = aB9cDeFgHiJkLmNoPqRsTuVwXyZ0123456789+AbCdE=',
    'PresharedKey = kJ8hG7fE6dC5bA4zY3xW2vU1tS0rQ9pO8nM7lK6jI5h=',
    'Endpoint = 1.2.3.4:51820', 'PersistentKeepalive = 25', 'AllowedIPs = 0.0.0.0/0', ''
  ].join('\n');
  const wg = parsers.parseWireGuardConfig(wgConf);
  assert.strictEqual(wg.type, 'wireguard');
  assert.strictEqual(wg.server, '1.2.3.4');
  assert.strictEqual(wg.port, 51820);
  assert.strictEqual(wg.ip, '10.0.0.2');
  assert.deepStrictEqual(wg.dns, ['77.88.8.8']);
  assert.strictEqual(wg['persistent-keepalive'], 25);
  assert.strictEqual(wg['amnezia-wg-option'].jc, 4);
  assert.strictEqual(wg['amnezia-wg-option'].s1, 5);

  // --- Amnezia JSON container (same doc as vpn:// payload) -----------------------
  const last = {
    hostName: '5.6.7.8', port: 34567,
    client_priv_key: 'a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5',
    server_pub_key: 'cHVia2V5cHVia2V5cHVia2V5cHVia2V5cHVia2V5',
    client_ip: '10.8.0.2/32', Jc: '4', S1: '116'
  };
  const amneziaDoc = {
    defaultContainer: 'amnezia-awg',
    containers: [{ container: 'amnezia-awg', awg: JSON.stringify({ last_config: JSON.stringify(last) }) }]
  };
  const awg = parsers.parseAmneziaVpnJson(amneziaDoc);
  assert.strictEqual(awg.type, 'wireguard');
  assert.strictEqual(awg.server, '5.6.7.8');
  assert.strictEqual(awg.port, 34567);
  assert.strictEqual(awg['amnezia-wg-option'].s1, 116);

  // --- subscription URL fallback entry -------------------------------------------
  const sub = parsers.parseSubscriptionUrl('https://panel.example.com/sub/abc123');
  assert.strictEqual(sub.type, 'http');
  assert.strictEqual(sub.url, 'https://panel.example.com/sub/abc123');

  // --- ss: edge cases & invalid inputs ----------------------------------------
  assert.strictEqual(parsers.parseSS('vless://example.com:443'), null);
  assert.strictEqual(parsers.parseSS('ss://invalid-url-without-port'), null);
  assert.strictEqual(parsers.parseSS('ss://!!!invalid-base64!!!'), null);

  // Full base64 host decodes to non-URL string
  const ssBadDecoded = Buffer.from('not-a-valid-url').toString('base64');
  assert.strictEqual(parsers.parseSS(`ss://${ssBadDecoded}`), null);

  // Base64 userinfo without colon (missing cipher or password separator)
  const ssNoColon = Buffer.from('noclonuser').toString('base64');
  assert.strictEqual(parsers.parseSS(`ss://${ssNoColon}@ss.example.com:8388`), null);

  // Empty cipher
  assert.strictEqual(parsers.parseSS('ss://:pass@ss.example.com:8388'), null);

  // Unknown plugin without semicolon or unhandled plugin
  const ssUnknownPlugin = parsers.parseSS('ss://chacha20:pass@ss.example.com:8388?plugin=someplugin');
  assert.strictEqual(ssUnknownPlugin.plugin, undefined);

  // --- garbage is rejected, not thrown --------------------------------------------
  assert.strictEqual(await parsers.parseProxyUrl('not a link at all'), null);
  assert.strictEqual(await parsers.parseProxyUrl(''), null);
  assert.strictEqual(parsers.parseWireGuardConfig('random text\nmore text'), null);
  assert.strictEqual(parsers.parseAmneziaVpnJson({ containers: [] }), null);

  console.log('parsers: all assertions passed');
}

main().catch((e) => { console.error(e); process.exit(1); });
