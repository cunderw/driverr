#!/usr/bin/env node
// testflight.mjs — the App Store Connect calls the TestFlight workflow makes.
//
//   testflight.mjs next-build <bundle-id> [--tag-max N]
//       Prints the larger of two numbers, plus one: the newest build number on the app
//       record, and N, the highest number in a `build/<version>-<number>` tag. App Store
//       Connect lists a build only after it finishes processing, so a build still
//       processing is known by its tag alone.
//
//   testflight.mjs release <bundle-id> <build> [--notes TEXT]
//       Waits up to 30 minutes for the uploaded build to finish processing, then does what
//       TestFlight leaves undone. Each step below is off unless its variable is set.
//       The upload has already succeeded when this runs, so after the build is VALID no
//       failure fails the run: each one is a warning and a line in the step summary. A
//       build that is still processing at the deadline is the same. A build that is
//       INVALID, FAILED or in any other state fails the run.
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
//
// Tests, with stubbed network calls and no credentials (not part of CI):
//   node --test scripts/testflight.test.mjs
import { createSign } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// The tests replace these. Nothing else reads them.
export const settings = {
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  pollMs: 30_000, // between two looks at the build
  polls: 60, // 60 looks, 30 s apart: 30 minutes
  groupRetryMs: 10_000, // between two tries to add the build to a group
  groupTries: 7, // 6 waits of 10 s: about a minute
};

const log = (...a) => console.error(...a);
const oneLine = (text) => String(text).split('\n')[0];

// A workflow command is read from the run's output, so it goes to stdout.
function warn(message) {
  console.log(`::warning::${oneLine(message)}`);
}

function summarize(line) {
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${line}\n`);
}

export class ApiError extends Error {
  constructor(method, path, status, text) {
    super(`${method} ${path} → ${status}\n${text}`);
    this.status = status;
    this.body = text;
  }
}

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
// its own. A thrown fetch error (a dropped connection) and a 5xx or 429 answer are retried
// the same way.
export async function api(method, path, body, attempt = 1) {
  const headers = {
    Authorization: `Bearer ${token()}`,
    ...(body ? { 'Content-Type': 'application/json' } : {}),
  };
  let res;
  let text;
  try {
    res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    text = await res.text();
  } catch (error) {
    const reason = `${error.message}${error.cause?.code ? ` (${error.cause.code})` : ''}`;
    if (attempt < 5) {
      log(`${method} ${path}: ${reason}, retrying`);
      await settings.sleep(1000 * 2 ** (attempt - 1));
      return api(method, path, body, attempt + 1);
    }
    throw new Error(`${method} ${path} failed: ${reason}`);
  }
  if (!res.ok) {
    if ((res.status >= 500 || res.status === 429) && attempt < 5) {
      await settings.sleep(1000 * 2 ** (attempt - 1));
      return api(method, path, body, attempt + 1);
    }
    throw new ApiError(method, path, res.status, text);
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

export async function nextBuild(bundleId, tagMax = 0) {
  const all = await builds(await findApp(bundleId));
  const numbers = all.map((b) => Number(b.attributes.version));
  if (numbers.some((n) => !Number.isInteger(n))) {
    throw new Error(`a build number on the record is not an integer: ${all.map((b) => b.attributes.version)}`);
  }
  return Math.max(0, tagMax, ...numbers) + 1;
}

// ABSENT is normal: /v1/builds lists a build only when processing has finished. Returns the
// build, or null when the deadline passes while it is still ABSENT or PROCESSING.
export async function waitForValid(appId, number) {
  for (let i = 0; i < settings.polls; i++) {
    const build = (await builds(appId)).find((b) => b.attributes.version === number);
    const state = build?.attributes.processingState ?? 'ABSENT';
    log(`build ${number}: ${state}`);
    if (state === 'VALID') return build;
    if (state !== 'ABSENT' && state !== 'PROCESSING') {
      throw new Error(`build ${number} is ${state}. Uploading the same archive again will not fix it.`);
    }
    await settings.sleep(settings.pollMs);
  }
  return null;
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

async function addToGroup(group, build) {
  for (let attempt = 1; ; attempt++) {
    try {
      await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, {
        data: [{ type: 'builds', id: build.id }],
      });
      return;
    } catch (error) {
      // A 404 right after VALID may be the build not yet visible to the group. That cause
      // is not confirmed, and no other call is retried on a 404.
      if (!(error instanceof ApiError) || error.status !== 404 || attempt >= settings.groupTries) throw error;
      log(`group "${group.attributes.name}": 404, trying again (${attempt} of ${settings.groupTries})`);
      await settings.sleep(settings.groupRetryMs);
    }
  }
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
    await addToGroup(groups.find((g) => g.attributes.name === name), build);
    log(`group "${name}": holds build ${build.attributes.version}`);
  }

  const detail = await api('GET', `/v1/builds/${build.id}/buildBetaDetail`);
  const state = detail.data.attributes.externalBuildState;
  if (state !== 'READY_FOR_BETA_SUBMISSION') {
    log(`Beta App Review: not submitted, externalBuildState is ${state}`);
    return;
  }
  try {
    await api('POST', '/v1/betaAppReviewSubmissions', {
      data: {
        type: 'betaAppReviewSubmissions',
        relationships: { build: { data: { type: 'builds', id: build.id } } },
      },
    });
  } catch (error) {
    // Beta App Review takes one build at a time. Nothing is wrong with this build.
    if (error instanceof ApiError && error.status === 422 && error.body.includes('ANOTHER_BUILD_IN_REVIEW')) {
      log('Beta App Review: skipped, another build is already in review');
      summarize(`Build ${build.attributes.version}: Beta App Review not requested, because another build is in review. Submit it in App Store Connect when that review ends.`);
      return;
    }
    throw error;
  }
  log('Beta App Review: submitted');
}

// The upload has succeeded by now. A failed call here is reported and never fails the run.
async function nonFatal(label, number, step) {
  try {
    await step();
  } catch (error) {
    log(`${label}: ${error.message}`);
    warn(`${label} failed for build ${number}: ${oneLine(error.message)}`);
    summarize(`Build ${number}: ${label} failed (${oneLine(error.message)}). The build is uploaded. Finish this step in App Store Connect.`);
  }
}

export async function release(bundleId, number, notes) {
  const appId = await findApp(bundleId);
  const build = await waitForValid(appId, number);
  if (!build) {
    const minutes = (settings.polls * settings.pollMs) / 60_000;
    log(`build ${number}: still not VALID after ${minutes} minutes`);
    warn(`build ${number} was still processing after ${minutes} minutes, so distribution was skipped. The upload succeeded. Do not upload it again.`);
    summarize(`Build ${number}: still processing after ${minutes} minutes. Distribution was skipped. Do not upload it again; finish distribution in App Store Connect once processing ends.`);
    return;
  }
  await nonFatal('export compliance', number, () => answerCompliance(build));
  await nonFatal('distribution', number, () => distributeExternally(appId, build, notes));
}

async function main(args) {
  const [command, bundleId, ...rest] = args;
  try {
    if (command === 'next-build' && bundleId) {
      const at = rest.indexOf('--tag-max');
      const tagMax = at === -1 ? 0 : Number(rest[at + 1]);
      if (!Number.isInteger(tagMax) || tagMax < 0) throw new Error('--tag-max takes a whole number');
      console.log(await nextBuild(bundleId, tagMax));
    } else if (command === 'release' && bundleId && rest[0]) {
      const at = rest.indexOf('--notes');
      await release(bundleId, rest[0], at === -1 ? '' : (rest[at + 1] ?? ''));
    } else {
      log('usage: testflight.mjs next-build <bundle-id> [--tag-max N]\n       testflight.mjs release <bundle-id> <build> [--notes TEXT]');
      process.exit(2);
    }
  } catch (error) {
    log(`error: ${error.message}`);
    process.exit(1);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main(process.argv.slice(2));
