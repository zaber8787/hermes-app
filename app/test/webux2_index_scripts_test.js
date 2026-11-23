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

// ---- entry log (TASK-WEBUX3-01) --------------------------------------------
// Static guards first: the block may navigate nothing (the four known
// spellings are not enough — location['reload'](), window.location= and
// history.go(0) all dodge them, so no 'location' word and no 'history.'
// may appear AT ALL, comments included) and it must not duplicate the
// single page-wide build marker (publish.sh aborts on a second one).
{
  const src = scriptSource('hermes-entry-log');
  assert.ok(!/\blocation\b/.test(src), 'entry log must not mention location');
  assert.ok(!/\bhistory\./.test(src), 'entry log must not touch history');
  assert.ok(!src.includes('__HERMES_BUILD_ID__'),
    'entry log must not carry a second build marker');
  assert.equal(html.split('__HERMES_BUILD_ID__').length, 2,
    'exactly one build marker page-wide');
}

async function runEntryLog({token, fetchOk, preload}) {
  const store = {};
  if (preload !== undefined) store['hermes.entrylog.v1'] = JSON.stringify(preload);
  if (token !== undefined) store['hermes.vault.server.key'] = token;
  const fetchCalls = [], nav = [], warns = [], timeouts = [], listeners = {};
  const ls = {
    getItem: k => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = v; },
  };
  const sandbox = {
    console: {warn(...a) { warns.push(a); }},
    fetch: (url, opts) => {
      fetchCalls.push({url, opts});
      return Promise.resolve({ok: fetchOk !== false});
    },
    setTimeout: fn => { timeouts.push(fn); return 1; },
    window: {
      localStorage: ls,
      addEventListener: (name, fn) => { listeners[name] = fn; },
    },
    location: {
      reload: () => nav.push('reload'),
      replace: () => nav.push('replace'),
      assign: () => nav.push('assign'),
    },
    history: {go: () => nav.push('go')},
  };
  vm.runInNewContext(scriptSource('hermes-entry-log'), sandbox);
  const buffer = () => JSON.parse(store['hermes.entrylog.v1'] || '[]');
  await new Promise(setImmediate);
  return {sandbox, store, fetchCalls, nav, warns, timeouts, listeners, buffer};
}

(async () => {
  {
    // Record point A: the deadline fires, one keepalive upload leaves,
    // a 2xx empties the buffer, nothing navigates.
    const h = await runEntryLog({token: 'tk'});
    assert.equal(h.timeouts.length, 1, 'entry log schedules its own deadline');
    h.timeouts[0]();
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'a record uploads exactly once');
    const {url, opts} = h.fetchCalls[0];
    assert.equal(url, '/clientlog', 'upload target');
    assert.ok(!url.includes('?'), 'nothing rides in a query string');
    assert.equal(opts.method, 'POST');
    assert.equal(opts.keepalive, true, 'keepalive outlives the dying page');
    assert.equal(opts.headers.Authorization, 'Bearer tk');
    const payload = JSON.parse(opts.body);
    assert.equal(payload.records.length, 1);
    const keys = Object.keys(payload.records[0]).sort();
    assert.deepEqual(keys, ['build', 'kind', 'ts'],
      'whitelisted fields only: {ts, kind, build}');
    assert.equal(payload.records[0].kind, 'boot-timeout');
    assert.equal(typeof payload.records[0].ts, 'number');
    assert.equal(payload.records[0].build, 'unknown',
      'no identity before the update script assigned one');
    assert.deepEqual(h.buffer(), [], 'a 2xx removes the sent batch');
    assert.deepEqual(h.nav, [], 'recording never navigates');
  }
  {
    // No token: the record stays buffered, no 'Bearer null' is ever sent.
    const h = await runEntryLog({});
    h.timeouts[0]();
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 0, 'a tokenless profile sends nothing');
    assert.equal(h.buffer().length, 1, 'the record stays buffered');
  }
  {
    // Record point B: the swallowed SW race is detected through the
    // console.warn wrapper, and the original warn keeps its arguments.
    const h = await runEntryLog({token: 'tk'});
    const err = new Error(
      'prepareServiceWorker took more than 4000ms to resolve. Moving on.');
    h.sandbox.console.warn('Exception while loading service worker:', err);
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'the race uploads once');
    assert.equal(JSON.parse(h.fetchCalls[0].opts.body).records[0].kind,
      'sw-timeout');
    assert.equal(h.warns.length, 1, 'original warn still called once');
    assert.equal(h.warns[0][0], 'Exception while loading service worker:');
    assert.equal(h.warns[0][1], err, 'original warn keeps its arguments');
    h.sandbox.console.warn('hermes-web: something else');
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'unrelated warns record nothing');
    assert.equal(h.warns.length, 2, 'unrelated warns still pass through');
  }
  {
    // Fallback: a successful boot flushes leftovers, at most once per
    // page lifetime, and the expired deadline then records nothing.
    const left = [{ts: 1, kind: 'sw-timeout', build: 'old'}];
    const h = await runEntryLog({token: 'tk', preload: left});
    h.listeners['flutter-first-frame']();
    h.listeners['flutter-first-frame']();
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'flush happens once per lifetime');
    assert.deepEqual(JSON.parse(h.fetchCalls[0].opts.body).records, left,
      'sent batch was the leftover');
    h.timeouts[0]();
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'a booted page records no timeout');
    assert.deepEqual(h.buffer(), [], 'flush success empties the buffer');
  }
  {
    // Buffer cap: 50 entries, oldest whole records dropped first.
    const preload = [];
    for (let i = 1; i <= 60; i++) {
      preload.push({ts: i, kind: 'boot-timeout', build: 'b'});
    }
    const h = await runEntryLog({preload});
    h.timeouts[0]();
    await new Promise(setImmediate);
    const buf = h.buffer();
    assert.equal(buf.length, 50, 'buffer is capped at 50 records');
    assert.equal(buf[0].ts, 12, 'the oldest whole records were dropped');
    assert.equal(buf[buf.length - 1].kind, 'boot-timeout',
      'the newest record survives the trim');
  }
  {
    // localStorage holding garbage must not throw the block.
    const h = await runEntryLog({token: 'tk'});
    h.store['hermes.entrylog.v1'] = 'not json';
    h.timeouts[0]();
    await new Promise(setImmediate);
    assert.equal(h.fetchCalls.length, 1, 'garbage buffer still recovers');
    assert.equal(JSON.parse(h.fetchCalls[0].opts.body).records.length, 1,
      'garbage is replaced, never uploaded');
  }
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
