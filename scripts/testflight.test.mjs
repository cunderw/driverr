// Tests for testflight.mjs. The network is stubbed and no credential is real.
//
//   node --test scripts/testflight.test.mjs
//
// Hosted CI runs the kit tier and nothing else, so this is a local run.
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, beforeEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { api, nextBuild, release, settings } from './testflight.mjs';

const dir = mkdtempSync(join(tmpdir(), 'testflight-test-'));
const keyPath = join(dir, 'AuthKey_TEST.p8');
const summaryPath = join(dir, 'summary.md');
writeFileSync(
  keyPath,
  generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' }),
);
process.env.ASC_KEY_ID = 'TESTKEY';
process.env.ASC_ISSUER_ID = 'test-issuer';
process.env.ASC_KEY_PATH = keyPath;
process.env.GITHUB_STEP_SUMMARY = summaryPath;
delete process.env.EXPORT_COMPLIANCE_EXEMPT;
delete process.env.TESTFLIGHT_EXTERNAL_GROUPS;

const realFetch = globalThis.fetch;
const realLog = console.log;
const realError = console.error;
const realSettings = { ...settings };

let sleeps;
let calls;
let out;

// `handler(method, path, body)` returns { status?, json? } or throws.
function stub(handler) {
  globalThis.fetch = async (url, init) => {
    const path = url.replace('https://api.appstoreconnect.apple.com', '');
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push(`${init.method} ${path}`);
    const { status = 200, json = null } = await handler(init.method, path, body);
    return new Response(json === null ? null : JSON.stringify(json), { status });
  };
}

beforeEach(() => {
  sleeps = [];
  calls = [];
  out = [];
  Object.assign(settings, realSettings, { sleep: async (ms) => void sleeps.push(ms) });
  writeFileSync(summaryPath, '');
  console.log = (...a) => out.push(a.join(' '));
  console.error = () => {};
  delete process.env.EXPORT_COMPLIANCE_EXEMPT;
  delete process.env.TESTFLIGHT_EXTERNAL_GROUPS;
});

after(() => {
  globalThis.fetch = realFetch;
  console.log = realLog;
  console.error = realError;
  rmSync(dir, { recursive: true, force: true });
});

const summary = () => readFileSync(summaryPath, 'utf8');
const warnings = () => out.filter((l) => l.startsWith('::warning::'));
const count = (prefix) => calls.filter((c) => c.startsWith(prefix)).length;

const app = { data: [{ id: 'app1', attributes: { bundleId: 'com.example.app' } }] };
const build = (version, processingState, usesNonExemptEncryption = false) => ({
  data: [{ id: `b${version}`, attributes: { version, processingState, usesNonExemptEncryption } }],
});

// A server whose build list is `states` in turn, then the last one for good.
function server(states, extra = () => undefined) {
  let polled = 0;
  return (method, path, body) => {
    if (path.startsWith('/v1/apps')) return { json: app };
    if (path.startsWith('/v1/builds?')) {
      const state = states[Math.min(polled++, states.length - 1)];
      return { json: state === 'ABSENT' ? { data: [] } : build('7', state) };
    }
    return extra(method, path, body) ?? { status: 500, json: { errors: [`unexpected ${method} ${path}`] } };
  };
}

const groupServer = (onPost, detailState = 'IN_BETA_TESTING', onSubmit) =>
  server(['VALID'], (method, path, body) => {
    if (path.startsWith('/v1/betaGroups?')) return { json: { data: [{ id: 'g1', attributes: { name: 'Beta' } }] } };
    if (method === 'POST' && path === '/v1/betaGroups/g1/relationships/builds') return onPost(body);
    if (path === '/v1/builds/b7/buildBetaDetail') {
      return { json: { data: { attributes: { externalBuildState: detailState } } } };
    }
    if (method === 'POST' && path === '/v1/betaAppReviewSubmissions') return onSubmit();
  });

test('a thrown fetch error is retried with the 5xx backoff, then passes', async () => {
  let n = 0;
  stub(() => {
    if (n++ < 2) throw new TypeError('fetch failed');
    return { json: { ok: true } };
  });
  assert.deepEqual(await api('GET', '/v1/apps'), { ok: true });
  assert.equal(n, 3);
  assert.deepEqual(sleeps, [1000, 2000]);
});

test('a fetch error on every try fails after five tries', async () => {
  stub(() => {
    throw new TypeError('fetch failed');
  });
  await assert.rejects(api('GET', '/v1/apps'), /fetch failed/);
  assert.equal(calls.length, 5);
  assert.deepEqual(sleeps, [1000, 2000, 4000, 8000]);
});

test('a build ABSENT from the list, then PROCESSING, then VALID, is released', async () => {
  stub(server(['ABSENT', 'ABSENT', 'PROCESSING', 'VALID']));
  await release('com.example.app', '7', '');
  assert.equal(count('GET /v1/builds?'), 4);
  assert.deepEqual(sleeps, [30_000, 30_000, 30_000]);
  assert.deepEqual(warnings(), []);
});

for (const state of ['ABSENT', 'PROCESSING']) {
  test(`a build still ${state} at the deadline warns and finishes, with no distribution`, async () => {
    process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
    settings.polls = 3;
    stub(server([state]));
    await release('com.example.app', '7', 'notes');
    assert.equal(count('GET /v1/builds?'), 3);
    assert.equal(warnings().length, 1);
    assert.match(warnings()[0], /build 7 was still processing/);
    assert.match(summary(), /Distribution was skipped/);
    assert.equal(count('POST'), 0);
    assert.equal(count('GET /v1/betaGroups'), 0);
  });
}

test('the default budget is 30 minutes of 30 s polls', () => {
  assert.equal((realSettings.polls * realSettings.pollMs) / 60_000, 30);
});

for (const state of ['INVALID', 'FAILED']) {
  test(`a ${state} build fails the run`, async () => {
    stub(server([state]));
    await assert.rejects(release('com.example.app', '7', ''), new RegExp(`build 7 is ${state}`));
    assert.deepEqual(warnings(), []);
  });
}

test('a group 404 is retried and then succeeds', async () => {
  process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
  let posts = 0;
  stub(groupServer(() => (++posts < 3 ? { status: 404, json: { errors: [{ code: 'NOT_FOUND' }] } } : {})));
  await release('com.example.app', '7', '');
  assert.equal(posts, 3);
  assert.deepEqual(sleeps, [10_000, 10_000]);
  assert.deepEqual(warnings(), []);
  assert.equal(summary(), '');
});

test('a group 404 on every try warns, finishes, and tries once per allowed try', async () => {
  process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
  stub(groupServer(() => ({ status: 404, json: { errors: [{ code: 'NOT_FOUND' }] } })));
  await release('com.example.app', '7', '');
  assert.equal(count('POST /v1/betaGroups/g1'), settings.groupTries);
  assert.equal(sleeps.length, settings.groupTries - 1);
  assert.equal(warnings().length, 1);
  assert.match(warnings()[0], /distribution failed for build 7/);
  assert.match(summary(), /distribution failed/);
  assert.equal(count('POST /v1/betaAppReviewSubmissions'), 0);
});

test('a 404 from any other call is not retried', async () => {
  process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
  stub(
    server(['VALID'], (method, path) => {
      if (path.startsWith('/v1/betaGroups?')) return { status: 404, json: { errors: [] } };
    }),
  );
  await release('com.example.app', '7', '');
  assert.equal(count('GET /v1/betaGroups?'), 1);
  assert.equal(warnings().length, 1);
});

test('a 422 ANOTHER_BUILD_IN_REVIEW is a skip, not a warning', async () => {
  process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
  stub(
    groupServer(
      () => ({}),
      'READY_FOR_BETA_SUBMISSION',
      () => ({ status: 422, json: { errors: [{ code: 'ENTITY_ERROR', detail: 'ANOTHER_BUILD_IN_REVIEW' }] } }),
    ),
  );
  await release('com.example.app', '7', '');
  assert.equal(count('POST /v1/betaAppReviewSubmissions'), 1);
  assert.deepEqual(warnings(), []);
  assert.match(summary(), /Beta App Review not requested/);
});

test('any other failure of the review submission is a warning', async () => {
  process.env.TESTFLIGHT_EXTERNAL_GROUPS = 'Beta';
  stub(
    groupServer(
      () => ({}),
      'READY_FOR_BETA_SUBMISSION',
      () => ({ status: 422, json: { errors: [{ code: 'ENTITY_ERROR' }] } }),
    ),
  );
  await release('com.example.app', '7', '');
  assert.equal(warnings().length, 1);
  assert.match(summary(), /distribution failed/);
});

test('an export compliance answer that App Store Connect refuses is a warning', async () => {
  process.env.EXPORT_COMPLIANCE_EXEMPT = 'true';
  stub((method, path) => {
    if (path.startsWith('/v1/apps')) return { json: app };
    if (path.startsWith('/v1/builds?')) return { json: build('7', 'VALID', null) };
    return { status: 409, json: { errors: [] } };
  });
  await release('com.example.app', '7', '');
  assert.equal(count('PATCH /v1/builds/b7'), 1);
  assert.equal(warnings().length, 1);
  assert.match(warnings()[0], /export compliance failed/);
});

test('the next build number is the larger of the record and the highest tag, plus one', async () => {
  const listed = { data: ['1', '2', '3'].map((v) => ({ id: v, attributes: { version: v } })) };
  stub((method, path) => ({ json: path.startsWith('/v1/apps') ? app : listed }));
  assert.equal(await nextBuild('com.example.app'), 4);
  assert.equal(await nextBuild('com.example.app', 0), 4);
  assert.equal(await nextBuild('com.example.app', 2), 4);
  assert.equal(await nextBuild('com.example.app', 3), 4);
  assert.equal(await nextBuild('com.example.app', 5), 6);
});

test('with no build on the record, a tag still sets the number', async () => {
  stub((method, path) => ({ json: path.startsWith('/v1/apps') ? app : { data: [] } }));
  assert.equal(await nextBuild('com.example.app'), 1);
  assert.equal(await nextBuild('com.example.app', 9), 10);
});

test('importing the script runs no command, and running it with no arguments prints usage', () => {
  const run = spawnSync(process.execPath, [fileURLToPath(new URL('./testflight.mjs', import.meta.url))], {
    encoding: 'utf8',
  });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /usage: testflight\.mjs/);
});
