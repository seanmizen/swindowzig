#!/usr/bin/env node
/**
 * Writes the engine percent-complete marker in `README.md`.
 *
 * The percent counts merged work only. Each issue with the `engine` label is
 * one unit. An issue closed as completed is done. An issue closed as not
 * planned, or with the `idea` label, does not count.
 *
 *   node scripts/progress.mjs           write the marker in README.md
 *   node scripts/progress.mjs --check   print the marker, and write nothing
 *
 * It needs the `gh` CLI. In CI, set `GH_TOKEN`.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const README = join(ROOT, 'README.md');
const CHECK = process.argv.includes('--check');

const START = '<!-- progress:start -->';
const END = '<!-- progress:end -->';

// The first state label that an open issue has gives its row.
const STATES = ['in-review', 'in-progress', 'ready', 'backlog'];

function fetchIssues() {
  const out = execFileSync(
    'gh',
    [
      'issue',
      'list',
      '--label',
      'engine',
      '--state',
      'all',
      '--limit',
      '1000',
      '--json',
      'labels,state,stateReason',
    ],
    { cwd: ROOT, encoding: 'utf8' },
  );
  return JSON.parse(out);
}

export function tally(issues) {
  const rows = {
    done: 0,
    'in-review': 0,
    'in-progress': 0,
    ready: 0,
    backlog: 0,
  };
  for (const issue of issues) {
    const labels = issue.labels.map((l) => l.name);
    if (labels.includes('idea')) continue;
    if (issue.state === 'CLOSED') {
      if (issue.stateReason === 'COMPLETED') rows.done++;
      continue;
    }
    rows[STATES.find((s) => labels.includes(s)) ?? 'backlog']++;
  }
  const total = Object.values(rows).reduce((sum, n) => sum + n, 0);
  return { rows, total, percent: total === 0 ? 0 : (100 * rows.done) / total };
}

function bar(percent) {
  const filled = Math.round(percent / 5);
  return '█'.repeat(filled) + '░'.repeat(20 - filled);
}

export function render({ rows, total, percent }) {
  const value = percent.toFixed(1);
  return [
    START,
    `![engine progress](https://img.shields.io/badge/engine-${value}%25-1D76DB)`,
    '',
    `**Engine: ${value}% complete** \`${bar(percent)}\` (${rows.done} of ${total} issues)`,
    '',
    '| State | Issues |',
    '|---|---|',
    ...Object.entries(rows).map(([state, n]) => `| ${state} | ${n} |`),
    '',
    'A GitHub workflow writes this block from the',
    '[`engine` issues](https://github.com/seanmizen/swindowzig/issues?q=label%3Aengine).',
    'Do not edit it. `scripts/progress.mjs` gives the rules.',
    END,
  ].join('\n');
}

function main() {
  const block = render(tally(fetchIssues()));
  if (CHECK) {
    console.log(block);
    return;
  }
  const readme = readFileSync(README, 'utf8');
  const start = readme.indexOf(START);
  const end = readme.indexOf(END);
  if (start === -1 || end === -1) {
    console.error(`README.md has no ${START} ... ${END} block.`);
    process.exit(1);
  }
  const next = readme.slice(0, start) + block + readme.slice(end + END.length);
  if (next !== readme) writeFileSync(README, next);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
