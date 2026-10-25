#!/usr/bin/env node
/**
 * Tests for requirements/check.mjs: where it looks for requirements, and what
 * counts as evidence.
 *
 * `node:test` and `node:assert` are Node stdlib — no new dependency, in
 * keeping with the checker itself. Run with:
 *
 *   node --test requirements/check.test.mjs
 */

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { after, test } from 'node:test';
import {
  collectCitations,
  evidencePath,
  evidenceProblem,
  requirementDirs,
} from './check.mjs';

// A fake repository: a root requirements folder, one app, and a debbie with a
// live generation and an archived one.
const root = mkdtempSync(join(tmpdir(), 'requirements-check-'));
after(() => rmSync(root, { recursive: true, force: true }));

const file = (path, text = '') => {
  const full = join(root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, text);
};

file('requirements/platform.md');
file('apps/web/requirements/nav.md');
file('apps/web/src/nav.ts', '// see REQ-NAV-001\n');
file('apps/web/node_modules/dep/requirements/dep.md');
file('utils/debbie/2026-09-17/requirements/server.md');
file('utils/debbie/2026-09-17/payload/assert.sh', '# REQ-SERVER-001\n');
file('utils/debbie/archive/2025-10-08b/requirements/server.md');
file('utils/debbie/archive/2025-10-08b/deploy.sh', '# REQ-SERVER-002\n');
file('utils/debbie/2025-12-27/deploy.sh');

const rel = (dirs) => dirs.map((d) => relative(root, d));

test('discovers a requirements folder at any depth under apps/ and utils/', () => {
  assert.deepEqual(rel(requirementDirs(root)), [
    'requirements',
    'apps/web/requirements',
    'utils/debbie/2026-09-17/requirements',
  ]);
});

test('skips archive/ and node_modules/ when discovering requirements', () => {
  const found = rel(requirementDirs(root)).join('\n');
  assert.doesNotMatch(found, /archive/);
  assert.doesNotMatch(found, /node_modules/);
});

test('skips archive/ when collecting citations', () => {
  const cited = collectCitations(root).map((c) => `${c.file} ${c.id}`);
  assert.deepEqual(cited.sort(), [
    'apps/web/src/nav.ts REQ-NAV-001',
    'utils/debbie/2026-09-17/payload/assert.sh REQ-SERVER-001',
  ]);
});

const live = join(root, 'utils/debbie/2026-09-17/requirements');

test('evidence inside the unit passes, written from the repo root', () => {
  assert.equal(
    evidenceProblem('utils/debbie/2026-09-17/payload/assert.sh', live, root),
    null,
  );
});

test('evidence must exist', () => {
  assert.equal(
    evidenceProblem('utils/debbie/2026-09-17/gone.sh', live, root),
    'points at a missing file',
  );
});

test('evidence cannot point into archive/', () => {
  assert.equal(
    evidenceProblem('utils/debbie/archive/2025-10-08b/deploy.sh', live, root),
    'points into archive/',
  );
});

test('evidence cannot point into another generation', () => {
  assert.equal(
    evidenceProblem('utils/debbie/2025-12-27/deploy.sh', live, root),
    'points outside its unit utils/debbie/2026-09-17',
  );
});

test('the root requirements folder may cite anything outside archive/', () => {
  const top = join(root, 'requirements');
  assert.equal(evidenceProblem('apps/web/src/nav.ts', top, root), null);
  assert.equal(
    evidenceProblem('utils/debbie/archive/2025-10-08b/deploy.sh', top, root),
    'points into archive/',
  );
});

test('a Test cites its first backticked text', () => {
  assert.equal(
    evidencePath('Test', 'Test — `a/spec.ts` › "name" and `b/other.ts`'),
    'a/spec.ts',
  );
});

test('an Inspection cites its first backticked repo path', () => {
  assert.equal(
    evidencePath('Inspection', 'Inspection — `trustProxy: true` in `a/b.ts`'),
    'a/b.ts',
  );
  assert.equal(
    evidencePath('Inspection', 'Inspection — `/usr/local/lib` holds units'),
    undefined,
  );
});
