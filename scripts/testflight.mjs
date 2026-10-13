#!/usr/bin/env node
// testflight.mjs — the App Store Connect calls the TestFlight workflow makes.
//
//   testflight.mjs next-build <bundle-id>
//       Prints the newest build number on the app record plus one.
//
//   testflight.mjs release <bundle-id> <build> [--notes TEXT]
//       Waits for the uploaded build to finish processing, then does what TestFlight
//       leaves undone. Each step below is off unless its variable is set.
//
// Credentials come from ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH. Nothing secret is read
// from or written to the repo. No dependencies: Node's own crypto signs the token.
//
//   EXPORT_COMPLIANCE_EXEMPT=true
//       Answers the build's export compliance question with "no non-exempt encryption".
//       `Info.plist` carries no answer on purpose, so App Store Connect asks on every
//       build and holds the build back from every tester until someone answers. This
//       variable is that answer, given by whoever sets it.
//   TESTFLIGHT_EXTERNAL_GROUPS="Name, Other Name"
//       Adds the build to those groups, writes --notes as What to Test, and submits the
//       build for Beta App Review when App Store Connect says it is ready for that.
//       An internal group takes every build by itself and needs none of this.
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.error(...a);

function token() {
  const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH } = process.env;
  if (!ASC_KEY_ID || !ASC_ISSUER_ID || !ASC_KEY_PATH) {
    throw new Error('ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set');
  }
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid: ASC_KEY_ID, typ: 'JWT' });
  const body = b64({ iss: ASC_ISSUER_ID, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' });
  const signer = createSign('SHA256');
  signer.update(`${head}.${body}`);
  const sig = signer
    .sign({ key: readFileSync(ASC_KEY_PATH, 'utf8'), dsaEncoding: 'ieee-p1363' })
    .toString('base64url');
  return `${head}.${body}.${sig}`;
}

// A token lasts 15 minutes and the wait for processing can outlast it, so each call signs
// its own.
async function api(method, path, body, attempt = 1) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  if (!res.ok) {
    if ((res.status >= 500 || res.status === 429) && attempt < 5) {
      await sleep(1000 * 2 ** (attempt - 1));
      return api(method, path, body, attempt + 1);
    }
    throw new Error(`${method} ${path} → ${res.status}\n${text}`);
  }
  return text ? JSON.parse(text) : null;
}

// Listed and matched here, because `filter[bundleId]` is not reliable on every account.
async function findApp(bundleId) {
  const apps = await api('GET', '/v1/apps?limit=200&fields[apps]=bundleId');
  const app = apps.data.find((a) => a.attributes.bundleId === bundleId);
  if (!app) throw new Error(`no app record for ${bundleId}`);
  return app.id;
}

async function builds(appId) {
  const res = await api(
    'GET',
    `/v1/builds?filter[app]=${appId}&sort=-uploadedDate&limit=200` +
      '&fields[builds]=version,processingState,usesNonExemptEncryption',
  );
  return res.data;
}

async function nextBuild(bundleId) {
  const all = await builds(await findApp(bundleId));
  const numbers = all.map((b) => Number(b.attributes.version));
  if (numbers.some((n) => !Number.isInteger(n))) {
    throw new Error(`a build number on the record is not an integer: ${all.map((b) => b.attributes.version)}`);
  }
  console.log(Math.max(0, ...numbers) + 1);
}

async function waitForValid(appId, number) {
  // 40 polls, 30 s apart.
  for (let i = 0; i < 40; i++) {
    const build = (await builds(appId)).find((b) => b.attributes.version === number);
    const state = build?.attributes.processingState ?? 'ABSENT';
    log(`build ${number}: ${state}`);
    if (state === 'VALID') return build;
    if (state !== 'ABSENT' && state !== 'PROCESSING') {
      throw new Error(`build ${number} is ${state}. Uploading the same archive again will not fix it.`);
    }
    await sleep(30_000);
  }
  throw new Error(`build ${number} did not reach VALID in 20 minutes. Do not upload it again.`);
}

async function answerCompliance(build) {
  if (build.attributes.usesNonExemptEncryption !== null) {
    log(`export compliance: already answered (${build.attributes.usesNonExemptEncryption})`);
    return;
  }
  if (process.env.EXPORT_COMPLIANCE_EXEMPT !== 'true') {
    log('export compliance: NOT answered. No tester gets this build until it is.');
    return;
  }
  await api('PATCH', `/v1/builds/${build.id}`, {
    data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } },
  });
  log('export compliance: answered, no non-exempt encryption');
}

async function writeNotes(build, notes) {
  const existing = await api('GET', `/v1/builds/${build.id}/betaBuildLocalizations`);
  const en = existing.data.find((l) => l.attributes.locale === 'en-US');
  if (en) {
    await api('PATCH', `/v1/betaBuildLocalizations/${en.id}`, {
      data: { type: 'betaBuildLocalizations', id: en.id, attributes: { whatsNew: notes } },
    });
  } else {
    await api('POST', '/v1/betaBuildLocalizations', {
      data: {
        type: 'betaBuildLocalizations',
        attributes: { locale: 'en-US', whatsNew: notes },
        relationships: { build: { data: { type: 'builds', id: build.id } } },
      },
    });
  }
  log('What to Test: written');
}

async function distributeExternally(appId, build, notes) {
  const wanted = (process.env.TESTFLIGHT_EXTERNAL_GROUPS ?? '')
    .split(',').map((s) => s.trim()).filter(Boolean);
  if (wanted.length === 0) {
    log('external groups: none named, internal testers only');
    return;
  }
  const groups = (await api('GET', `/v1/betaGroups?filter[app]=${appId}&limit=200&fields[betaGroups]=name`)).data;
  const missing = wanted.filter((name) => !groups.some((g) => g.attributes.name === name));
  if (missing.length) throw new Error(`no TestFlight group named: ${missing.join(', ')}`);

  if (notes) await writeNotes(build, notes);
  for (const name of wanted) {
    const group = groups.find((g) => g.attributes.name === name);
    await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, {
      data: [{ type: 'builds', id: build.id }],
    });
    log(`group "${name}": holds build ${build.attributes.version}`);
  }

  const detail = await api('GET', `/v1/builds/${build.id}/buildBetaDetail`);
  const state = detail.data.attributes.externalBuildState;
  if (state !== 'READY_FOR_BETA_SUBMISSION') {
    log(`Beta App Review: not submitted, externalBuildState is ${state}`);
    return;
  }
  await api('POST', '/v1/betaAppReviewSubmissions', {
    data: {
      type: 'betaAppReviewSubmissions',
      relationships: { build: { data: { type: 'builds', id: build.id } } },
    },
  });
  log('Beta App Review: submitted');
}

async function release(bundleId, number, notes) {
  const appId = await findApp(bundleId);
  const build = await waitForValid(appId, number);
  await answerCompliance(build);
  await distributeExternally(appId, build, notes);
}

const [command, bundleId, ...rest] = process.argv.slice(2);
try {
  if (command === 'next-build' && bundleId) {
    await nextBuild(bundleId);
  } else if (command === 'release' && bundleId && rest[0]) {
    const at = rest.indexOf('--notes');
    await release(bundleId, rest[0], at === -1 ? '' : (rest[at + 1] ?? ''));
  } else {
    log('usage: testflight.mjs next-build <bundle-id>\n       testflight.mjs release <bundle-id> <build> [--notes TEXT]');
    process.exit(2);
  }
} catch (error) {
  log(`error: ${error.message}`);
  process.exit(1);
}
