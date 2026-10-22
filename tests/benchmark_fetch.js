'use strict';
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const RU_APP_LIST_URL = 'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/ru-app-list.yaml';

function syncCurlFetch(url, tmpFile) {
  execSync(`curl -fsSL "${url}" -o "${tmpFile}"`);
  return fs.readFileSync(tmpFile, 'utf8');
}

async function asyncNativeFetch(url, tmpFile) {
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  fs.writeFileSync(tmpFile, text, 'utf8');
  return text;
}

async function runBenchmark() {
  const tmpFileSync = path.join(__dirname, '.bench_sync.tmp');
  const tmpFileAsync = path.join(__dirname, '.bench_async.tmp');

  const iterations = 3;

  console.log(`Running benchmark against remote URL (${iterations} iterations)...`);

  // Warmup
  syncCurlFetch(RU_APP_LIST_URL, tmpFileSync);
  await asyncNativeFetch(RU_APP_LIST_URL, tmpFileAsync);

  // Sync execSync benchmark
  const syncStart = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) {
    syncCurlFetch(RU_APP_LIST_URL, tmpFileSync);
  }
  const syncEnd = process.hrtime.bigint();
  const syncTotalMs = Number(syncEnd - syncStart) / 1e6;
  const syncAvgMs = syncTotalMs / iterations;

  // Async native fetch benchmark (sequential)
  const asyncStart = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) {
    await asyncNativeFetch(RU_APP_LIST_URL, tmpFileAsync);
  }
  const asyncEnd = process.hrtime.bigint();
  const asyncTotalMs = Number(asyncEnd - asyncStart) / 1e6;
  const asyncAvgMs = asyncTotalMs / iterations;

  // Cleanup files
  if (fs.existsSync(tmpFileSync)) fs.unlinkSync(tmpFileSync);
  if (fs.existsSync(tmpFileAsync)) fs.unlinkSync(tmpFileAsync);

  console.log(`\n=== Benchmark Results ===`);
  console.log(`execSync(curl): avg ${syncAvgMs.toFixed(2)} ms per fetch (total ${syncTotalMs.toFixed(2)} ms)`);
  console.log(`native fetch:   avg ${asyncAvgMs.toFixed(2)} ms per fetch (total ${asyncTotalMs.toFixed(2)} ms)`);
  console.log(`Speedup:        ${(syncAvgMs / asyncAvgMs).toFixed(2)}x faster`);
  console.log(`Process overhead & network saved per call: ${(syncAvgMs - asyncAvgMs).toFixed(2)} ms`);
}

runBenchmark().then(() => process.exit(0)).catch((err) => {
  console.error(err);
  process.exit(1);
});
