// TASK-WEBUX2-01 Ticket B: execute the shipped inline scripts from
// app/web/index.html against deterministic browser IO. Targeted by id so
// the WEBSYNC update script (web_update_test.js owns that one) is untouched.
// Assertions fail with plain AssertionError (a red the gate accepts); the
// scripts themselves must never call reload/assign/replace (no navigation).
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
function scriptSource(id) {
  const m = html.match(
    new RegExp('<script id="' + id + '">([\\s\\S]*?)<\\/script>'));
  assert.ok(m, 'index.html is missing <script id="' + id + '">');
  return m[1];
}

// ---- shared entry ---------------------------------------------------------
function runShare(hash) {
  const stored = {}, reloaded = [];
  const sandbox = {
    console: {warn() {}},
    URLSearchParams,
    location: {hash, pathname: '/', search: ''},
    history: {
      replaceState(state, title, url) { reloaded.push(url); },
      state: null,
    },
    window: {localStorage: {
      setItem: (k, v) => { stored[k] = v; },
    }},
  };
  vm.runInNewContext(scriptSource('hermes-share-entry'), sandbox);
  return {stored, reloaded};
}

{
  const {stored, reloaded} = runShare('#token=t1&server=https%3A%2F%2Fx.ts.net');
  assert.equal(stored['hermes.vault.server.key'], 't1',
    'token lands in the vault key the app reads');
  assert.equal(stored['flutter.server.url'], '"https://x.ts.net"',
    'server lands JSON-encoded under the shared_preferences_web prefix');
  assert.deepEqual(reloaded, ['/'], 'fragment is wiped before anything else');
  assert.ok(!reloaded.some(u => u.includes('#')), 'wipe target carries no fragment');
}
{
  // A launch deep link is NOT an entry: nothing stored, history untouched.
  const {stored, reloaded} = runShare('#/chat?session=a');
  assert.deepEqual(stored, {}, 'deep link stores nothing');
  assert.deepEqual(reloaded, [], 'deep link touches no history');
}
{
  // Token in the fragment, no server: keep the stored URL, take the token.
  const {stored} = runShare('#token=abc');
  assert.equal(stored['hermes.vault.server.key'], 'abc');
  assert.ok(!('flutter.server.url' in stored), 'absent server must not overwrite');
}
{
  const {stored} = runShare('');
  assert.deepEqual(stored, {}, 'no hash stores nothing');
}

// ---- boot watchdog --------------------------------------------------------
async function runWatchdog({firstFrameBeforeExpiry}) {
  const appended = [], reloaded = [];
  let timeoutFn = null;
  const listeners = {};
  const sandbox = {
    console: {warn() {}},
    navigator: {language: 'en'},
    location: {reload() { reloaded.push('reload'); }},
    document: {
      documentElement: {lang: 'en'},
      readyState: 'complete',
      createElement: () => ({
        style: {}, setAttribute() {}, remove() {},
      }),
      body: {appendChild: el => appended.push(el)},
      addEventListener(name, fn) { listeners[name] = fn; },
    },
    window: {
      addEventListener(name, fn) { listeners[name] = fn; },
    },
    setTimeout: fn => { timeoutFn = fn; return 1; },
  };
  vm.runInNewContext(scriptSource('hermes-boot-watchdog'), sandbox);
  assert.ok(timeoutFn, 'watchdog schedules its deadline');
  if (firstFrameBeforeExpiry && listeners['flutter-first-frame']) {
    listeners['flutter-first-frame']();
  }
  timeoutFn();
  return {appended, reloaded, firedFirstFrame: !!listeners['flutter-first-frame']};
}

(async () => {
  {
    const r = await runWatchdog({firstFrameBeforeExpiry: false});
    assert.ok(r.firedFirstFrame, 'watchdog listens for flutter-first-frame');
    assert.equal(r.appended.length, 1, 'silent boot shows a visible notice');
    assert.deepEqual(r.reloaded, [], 'watchdog never navigates on its own');
  }
  {
    const r = await runWatchdog({firstFrameBeforeExpiry: true});
    assert.equal(r.appended.length, 0, 'a booted app gets no notice');
    assert.deepEqual(r.reloaded, [], 'watchdog never navigates on its own');
  }
  console.log('webux2 index scripts pass');
})().catch(error => { console.error(error); process.exitCode = 1; });
