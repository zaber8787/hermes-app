// Execute the shipped inline update script against deterministic browser IO.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8')
  .replace('__HERMES_BUILD_ID__', 'old-build');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];

async function scenario(firstFails) {
  let calls = 0;
  const intervals = [], timeouts = [], chips = [];
  const sandbox = {
    URL, console: {warn() {}}, navigator: {language: 'en'},
    location: {reload() {}},
    document: {
      baseURI: 'https://test.invalid/', readyState: 'complete',
      documentElement: {lang: 'en'},
      createElement: () => ({style: {}, setAttribute() {}, addEventListener() {}}),
      body: {appendChild: chip => chips.push(chip)},
    },
    window: {addEventListener() {}},
    setTimeout: f => timeouts.push(f),
    setInterval: f => intervals.push(f),
    fetch: async () => {
      calls++;
      if (firstFails && calls === 1) throw Error('offline');
      return {ok: true, json: async () => ({build: calls < 3 ? 'old-build' : 'new-build'})};
    },
  };
  vm.runInNewContext(script, sandbox);
  await new Promise(setImmediate);
  assert.equal(timeouts.length, 1, 'first check is always scheduled');
  assert.equal(intervals.length, 1, 'periodic check survives initial failure');
  await timeouts[0]();
  assert.equal(chips.length, 0, 'same build is not an update');
  await intervals[0]();
  assert.equal(chips.length, 1, 'new build is compared to loaded bundle');
}

(async () => {
  await scenario(false);
  await scenario(true);
  console.log('web update checks pass');
})().catch(error => { console.error(error); process.exitCode = 1; });
