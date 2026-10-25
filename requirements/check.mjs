#!/usr/bin/env node
/**
 * Validator and index generator for the requirements in this repository.
 *
 * See `requirements/README.md` for the format this enforces. The rules here
 * are the whole reason the ceremony is worth anything: a requirement nobody
 * checks is prose, and prose is what let REQ-CHIPS-001 be traded away in
 * seanorepo#197 without anyone noticing.
 *
 *   node requirements/check.mjs           validate, and fail on a stale index
 *   node requirements/check.mjs --write   regenerate every index.md
 *
 * Deliberately dependency-free and run straight from source: a requirements
 * check that needs an install step is one that gets skipped.
 */

import {
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const WRITE = process.argv.includes('--write');

const STATUSES = ['proposed', 'active', 'superseded', 'withdrawn'];
const TYPES = ['functional', 'constraint', 'quality'];
const METHODS = ['Test', 'Analysis', 'Inspection', 'Demonstration'];
const REQUIRED_FIELDS = [
  'Status',
  'Source',
  'Origin',
  'Type',
  'Priority',
  'Statement',
  'Rationale',
  'Verification',
  'Relations',
];

/**
 * Only forward relations are stored. `required-by` and `refined-by` are
 * derived for the index and must never be hand-written, or the two directions
 * drift. Supersession is the exception: the superseded requirement has to be
 * edited anyway to change its status, and recording the back-link there is
 * what makes a dead requirement self-explanatory when read on its own.
 */
const RELATIONS = [
  'depends-on',
  'refines',
  'conflicts-with',
  'supersedes',
  'superseded-by',
  'amends',
  'amended-by',
  'verified-by',
];

const ID_PATTERN = /^REQ-[A-Z][A-Z0-9]*-\d{3}$/;
const HEADING = /^##\s+(REQ-[A-Z0-9-]+)\s+—\s+(.+?)\s*$/;
const FIELD = /^-\s+\*\*([A-Za-z-]+):\*\*\s*(.*)$/;
const NESTED = /^ {2}-\s+(.+?)\s*$/;
const CONTINUATION = /^ {2}(?! *-\s)(\S.*)$/;

const errors = [];
const fail = (file, id, message) =>
  errors.push(`${file}${id ? ` [${id}]` : ''}: ${message}`);

const warnings = [];
const warn = (file, id, message) =>
  warnings.push(`${file}${id ? ` [${id}]` : ''}: ${message}`);

/**
 * Every directory that holds requirement files: the root `requirements/`, and
 * a `requirements/` at any depth under `apps/` and `utils/`.
 *
 * `archive/` holds retired work. Its requirements are history, so the walk
 * does not enter it. Only the live generation counts.
 */
export const requirementDirs = (root = ROOT) => {
  const dirs = [];
  const rootDir = join(root, 'requirements');
  if (existsSync(rootDir)) dirs.push(rootDir);

  const found = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory() || isSkippedDir(entry.name)) continue;
      const full = join(dir, entry.name);
      if (entry.name === 'requirements') {
        found.push(full);
        continue;
      }
      walk(full);
    }
  };

  for (const group of ['apps', 'utils']) {
    const groupDir = join(root, group);
    if (existsSync(groupDir) && statSync(groupDir).isDirectory()) {
      walk(groupDir);
    }
  }
  return [...dirs, ...found.sort()];
};

/** The requirement files in a directory. README and the generated index are not. */
const requirementFiles = (dir) =>
  readdirSync(dir)
    .filter((name) => name.endsWith('.md'))
    .filter((name) => name !== 'README.md' && name !== 'index.md')
    .sort()
    .map((name) => join(dir, name));

/**
 * Directories that never contain a citation worth checking, plus anything a
 * build produced.
 */
const CITATION_SKIP_DIRS = new Set([
  '.git',
  '.next',
  '.zig-cache',
  'build',
  'coverage',
  'dist',
  'node_modules',
  'playwright-report',
  'test-results',
  'uploads',
  'zig-out',
]);

/**
 * A directory no walk enters: build output, dependencies, and `archive/`.
 * Archived code and requirements are retired, so neither counts.
 */
const isSkippedDir = (name) =>
  CITATION_SKIP_DIRS.has(name) || name === 'archive';

/** Extensions worth opening. Keeps the walk off binaries and lockfiles. */
const CITATION_EXTENSIONS = new Set([
  '.css',
  '.go',
  '.html',
  '.js',
  '.jsx',
  '.md',
  '.mjs',
  '.sh',
  '.sql',
  '.ts',
  '.tsx',
  '.yaml',
  '.yml',
  '.zig',
]);

const CITATION = /REQ-[A-Z][A-Z0-9]*-\d{3}/g;

/**
 * Every requirement citation in the codebase, with where it is.
 *
 * `requirements/` directories are skipped on purpose. They are the declaration
 * side, and README.md there uses illustrative IDs like REQ-X-001 to show the
 * format — examples, not references to anything.
 *
 * `archive/` directories are skipped too. A retired generation may cite
 * requirements that have since changed, and it runs nowhere.
 */
export const collectCitations = (root = ROOT) => {
  const found = [];

  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);

      if (entry.isDirectory()) {
        if (isSkippedDir(entry.name)) continue;
        if (entry.name === 'requirements') continue;
        walk(full);
        continue;
      }

      const dot = entry.name.lastIndexOf('.');
      if (dot === -1 || !CITATION_EXTENSIONS.has(entry.name.slice(dot))) {
        continue;
      }

      const text = readFileSync(full, 'utf8');
      if (!text.includes('REQ-')) continue;

      for (const [index, line] of text.split('\n').entries()) {
        for (const match of line.matchAll(CITATION)) {
          found.push({
            file: relative(root, full),
            line: index + 1,
            id: match[0],
          });
        }
      }
    }
  };

  walk(root);
  return found;
};

/**
 * Parse one file into requirements.
 *
 * A field is `- **Key:** value`, and its value may continue on following
 * two-space-indented lines or be given as a two-space-indented nested list.
 */
const parseFile = (path) => {
  const rel = relative(ROOT, path);
  const lines = readFileSync(path, 'utf8').split('\n');
  const found = [];
  let current = null;
  let field = null;

  const closeField = () => {
    if (current && field) {
      current.fields[field.key] = field.values.filter((v) => v.length > 0);
    }
    field = null;
  };

  for (const [index, line] of lines.entries()) {
    const heading = HEADING.exec(line);
    if (heading) {
      closeField();
      current = {
        id: heading[1],
        title: heading[2],
        file: rel,
        path,
        line: index + 1,
        fields: {},
      };
      found.push(current);
      continue;
    }

    if (!current) continue;

    // A new h2 that is not a requirement ends the current one.
    if (line.startsWith('## ')) {
      closeField();
      current = null;
      continue;
    }

    const fieldMatch = FIELD.exec(line);
    if (fieldMatch) {
      closeField();
      field = { key: fieldMatch[1], values: [fieldMatch[2].trim()] };
      continue;
    }

    if (!field) continue;

    const nested = NESTED.exec(line);
    if (nested) {
      field.values.push(nested[1]);
      continue;
    }

    const continuation = CONTINUATION.exec(line);
    if (continuation) {
      const last = field.values.length - 1;
      field.values[last] = `${field.values[last]} ${continuation[1]}`.trim();
      continue;
    }

    if (line.trim().length === 0) closeField();
  }

  closeField();
  return found;
};

const checkStatement = (req) => {
  const statement = (req.fields.Statement ?? []).join(' ').trim();
  if (statement.length === 0) return;

  const shalls = statement.match(/\bshall\b/g) ?? [];
  if (shalls.length === 0) {
    fail(
      req.file,
      req.id,
      'Statement has no "shall" (ISO 29148 reserves it for requirements)',
    );
  } else if (shalls.length > 1) {
    fail(
      req.file,
      req.id,
      `Statement has ${shalls.length} "shall"s — a requirement is Singular (ISO 29148). Split it.`,
    );
  }

  for (const wrong of ['must', 'should']) {
    if (new RegExp(`\\b${wrong}\\b`, 'i').test(statement)) {
      fail(
        req.file,
        req.id,
        `Statement uses "${wrong}" — ISO 29148 requires "shall"`,
      );
    }
  }

  if (!/[.]$/.test(statement)) {
    fail(req.file, req.id, 'Statement does not end in a full stop');
  }

  // EARS: a leading keyword introduces a clause that must be closed before the
  // response, or the requirement reads as an unbounded obligation.
  const shallAt = statement.search(/\bshall\b/);
  if (/^(When|While|Where)\b/.test(statement)) {
    const comma = statement.indexOf(',');
    if (comma === -1 || comma > shallAt) {
      fail(
        req.file,
        req.id,
        'EARS: a When/While/Where clause must be closed by a comma before "shall"',
      );
    }
  }
  if (/^If\b/.test(statement) && !/\bthen\b/.test(statement)) {
    fail(req.file, req.id, 'EARS: an "If" requirement must contain "then"');
  }
};

const checkVerification = (req) => {
  const entries = req.fields.Verification ?? [];
  if (entries.length === 0) {
    fail(req.file, req.id, 'Verification is empty');
    return;
  }

  for (const entry of entries) {
    const method = METHODS.find((m) => entry.startsWith(`${m} —`));
    if (!method) {
      fail(
        req.file,
        req.id,
        `Verification entry must start with one of ${METHODS.join('/')} followed by " — ": ${entry}`,
      );
      continue;
    }

    // A Test or Inspection link names a file, and that file has to still
    // exist — a spec renamed out from under a requirement is exactly the
    // silent drop this whole system exists to catch.
    if (method !== 'Test' && method !== 'Inspection') continue;

    const target = evidencePath(method, entry);
    if (!target) {
      if (method === 'Test') {
        fail(req.file, req.id, `Test verification names no file: ${entry}`);
      }
      continue;
    }

    const problem = evidenceProblem(target, dirname(req.path));
    if (problem) {
      fail(req.file, req.id, `${method} verification ${problem}: ${target}`);
    }
  }
};

/**
 * The file a Test or Inspection entry cites: the first path in backticks.
 *
 * For a Test that is simply the first backticked text. An Inspection may name
 * a setting or a host path first, e.g. `trustProxy: true` or
 * `/usr/local/lib/systemd/system`, so it takes the first backticked text that
 * reads as a repo path: no spaces, not absolute, with a `/` in it. An
 * Inspection with no repo path inspects the running system, and passes.
 */
export const evidencePath = (method, entry) => {
  const quoted = [...entry.matchAll(/`([^`]+)`/g)].map((m) => m[1]);
  if (method === 'Test') return quoted[0];
  return quoted.find(
    (text) => text.includes('/') && !/\s/.test(text) && !text.startsWith('/'),
  );
};

/**
 * Why a cited file is not valid evidence, or null when it is.
 *
 * Paths are written from the repo root. The file has to exist, and it has to
 * sit inside the unit that owns the requirements folder: the folder's parent.
 * So a debbie generation's requirements cannot be met by another generation's
 * code, and nothing is met by code in `archive/`. The root `requirements/`
 * folder's unit is the whole repo.
 */
export const evidenceProblem = (target, requirementsDir, root = ROOT) => {
  const full = resolve(root, target);
  if (!existsSync(full)) return 'points at a missing file';

  const inRepo = relative(root, full);
  if (inRepo.split(sep).includes('archive')) return 'points into archive/';

  const unit = dirname(requirementsDir);
  const inUnit = relative(unit, full);
  if (inUnit.startsWith('..') || isAbsolute(inUnit)) {
    return `points outside its unit ${relative(root, unit) || '.'}`;
  }
  return null;
};

const parseRelations = (req) => {
  const entries = req.fields.Relations ?? [];
  if (entries.length === 1 && entries[0].toLowerCase() === 'none') return [];

  const parsed = [];
  for (const entry of entries) {
    const match = /^([a-z-]+)\s+(REQ-[A-Z0-9-]+)$/.exec(entry.trim());
    if (!match) {
      fail(
        req.file,
        req.id,
        `Relation must read "<relation> REQ-X-NNN": ${entry}`,
      );
      continue;
    }
    if (!RELATIONS.includes(match[1])) {
      fail(
        req.file,
        req.id,
        `Unknown relation "${match[1]}" (allowed: ${RELATIONS.join(', ')})`,
      );
      continue;
    }
    parsed.push({ relation: match[1], target: match[2] });
  }
  return parsed;
};

/** `depends-on` describes what must hold first, so a cycle is unsatisfiable. */
const checkCycles = (byId) => {
  const state = new Map();

  const visit = (id, trail) => {
    if (state.get(id) === 'done') return;
    if (state.get(id) === 'open') {
      const from = trail.indexOf(id);
      const cycle = [...trail.slice(from), id].join(' → ');
      fail('requirements', null, `depends-on cycle: ${cycle}`);
      return;
    }

    state.set(id, 'open');
    for (const { relation, target } of byId.get(id)?.relations ?? []) {
      if (relation === 'depends-on' && byId.has(target)) {
        visit(target, [...trail, id]);
      }
    }
    state.set(id, 'done');
  };

  for (const id of byId.keys()) visit(id, []);
};

const mermaidId = (id) => id.replace(/-/g, '_');

/**
 * The anchor GitHub generates for a heading: lowercased, punctuation dropped,
 * spaces hyphenated. The em dash separator leaves the two spaces around it, so
 * the ID and the title end up separated by a double hyphen.
 */
const anchor = (req) =>
  `${req.id} — ${req.title}`
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s/g, '-');

const buildIndex = (dir, requirements, byId) => {
  const rel = relative(ROOT, dir) || '.';
  const local = requirements.filter((r) => dirname(r.path) === dir);
  const lines = [];

  lines.push(`# Requirements index — \`${rel}\``);
  lines.push('');
  lines.push(
    '<!-- GENERATED by requirements/check.mjs — do not edit by hand. -->',
  );
  lines.push('<!-- Regenerate with `yarn requirements:build`. -->');
  lines.push('');

  if (local.length === 0) {
    lines.push('No requirements yet.');
    lines.push('');
    return lines.join('\n');
  }

  lines.push('| ID | Title | Status | Type | Priority | Source |');
  lines.push('|---|---|---|---|---|---|');
  for (const req of local) {
    const f = req.fields;
    lines.push(
      `| [\`${req.id}\`](${basename(req.path)}#${anchor(req)}) | ${req.title} | ${first(f.Status)} | ${first(f.Type)} | ${first(f.Priority)} | ${first(f.Source)} |`,
    );
  }
  lines.push('');

  // The graph, including any target outside this directory so a cross-level
  // dependency is visible from the level that declares it.
  const edges = [];
  const nodes = new Set(local.map((r) => r.id));
  for (const req of local) {
    for (const { relation, target } of req.relations) {
      nodes.add(target);
      edges.push({ from: req.id, relation, target });
    }
  }

  lines.push('## Dependency graph');
  lines.push('');
  if (edges.length === 0) {
    lines.push('No relations declared yet.');
  } else {
    lines.push('```mermaid');
    lines.push('graph TD');
    for (const id of [...nodes].sort()) {
      const req = byId.get(id);
      const title = req ? req.title : 'external';
      lines.push(`  ${mermaidId(id)}["${id}<br/>${title}"]`);
    }
    for (const { from, relation, target } of edges) {
      lines.push(`  ${mermaidId(from)} -->|${relation}| ${mermaidId(target)}`);
    }
    for (const id of [...nodes].sort()) {
      const status = first(byId.get(id)?.fields.Status ?? []);
      if (status === 'superseded' || status === 'withdrawn') {
        lines.push(`  style ${mermaidId(id)} stroke-dasharray: 4 4`);
      }
    }
    lines.push('```');
  }
  lines.push('');

  // Derived inverses. Never stored, so they cannot drift out of step.
  const inverse = new Map();
  const addInverse = (target, text) => {
    if (!inverse.has(target)) inverse.set(target, []);
    inverse.get(target).push(text);
  };
  for (const req of requirements) {
    for (const { relation, target } of req.relations) {
      if (relation === 'depends-on')
        addInverse(target, `required-by ${req.id}`);
      if (relation === 'refines') addInverse(target, `refined-by ${req.id}`);
    }
  }

  const derived = local.filter((r) => inverse.has(r.id));
  if (derived.length > 0) {
    lines.push('## Derived reverse links');
    lines.push('');
    for (const req of derived) {
      lines.push(`- \`${req.id}\` — ${inverse.get(req.id).join(', ')}`);
    }
    lines.push('');
  }

  return lines.join('\n');
};

const first = (values) => (values && values.length > 0 ? values[0] : '');

// ---------------------------------------------------------------------------

/** Validate everything, then check or write the indexes. */
const main = () => {
  const dirs = requirementDirs();
  const requirements = [];
  for (const dir of dirs) {
    for (const path of requirementFiles(dir)) {
      requirements.push(...parseFile(path));
    }
  }

  const byId = new Map();
  for (const req of requirements) {
    if (!ID_PATTERN.test(req.id)) {
      fail(req.file, req.id, 'ID must look like REQ-PREFIX-001');
    }

    const prefix = req.id.split('-')[1];
    const expected = basename(req.path, '.md').toUpperCase();
    if (prefix !== expected) {
      fail(
        req.file,
        req.id,
        `prefix ${prefix} does not match filename (expected REQ-${expected}-*)`,
      );
    }

    if (byId.has(req.id)) {
      fail(
        req.file,
        req.id,
        `duplicate ID, already defined in ${byId.get(req.id).file}`,
      );
      continue;
    }
    byId.set(req.id, req);
  }

  for (const req of requirements) {
    for (const key of REQUIRED_FIELDS) {
      if (!req.fields[key] || req.fields[key].length === 0) {
        fail(req.file, req.id, `missing required field "${key}"`);
      }
    }

    const status = first(req.fields.Status ?? []);
    if (status && !STATUSES.includes(status)) {
      fail(
        req.file,
        req.id,
        `Status "${status}" is not one of ${STATUSES.join('/')}`,
      );
    }
    const type = first(req.fields.Type ?? []);
    if (type && !TYPES.includes(type)) {
      fail(req.file, req.id, `Type "${type}" is not one of ${TYPES.join('/')}`);
    }
    const priority = first(req.fields.Priority ?? []);
    if (priority && !/^P[0-3]$/.test(priority)) {
      fail(req.file, req.id, `Priority "${priority}" is not P0-P3`);
    }

    checkStatement(req);
    checkVerification(req);
    req.relations = parseRelations(req);
  }

  for (const req of requirements) {
    const status = first(req.fields.Status ?? []);
    const supersededBy = req.relations.filter(
      (r) => r.relation === 'superseded-by',
    );

    for (const { relation, target } of req.relations) {
      if (!byId.has(target)) {
        fail(
          req.file,
          req.id,
          `relation "${relation}" points at unknown ${target}`,
        );
        continue;
      }
      if (target === req.id) {
        fail(req.file, req.id, `relation "${relation}" points at itself`);
      }

      // Supersession and amendment are recorded on both sides, so a dead
      // requirement says so when read alone.
      const other = byId.get(target);
      const back = { supersedes: 'superseded-by', amends: 'amended-by' }[
        relation
      ];
      if (back) {
        const matched = other.relations.some(
          (r) => r.relation === back && r.target === req.id,
        );
        if (!matched) {
          fail(other.file, other.id, `should record "${back} ${req.id}"`);
        }
      }
    }

    if (status === 'superseded' && supersededBy.length === 0) {
      fail(
        req.file,
        req.id,
        'Status is superseded but no "superseded-by" relation is recorded',
      );
    }
    if (status === 'active' && supersededBy.length > 0) {
      fail(
        req.file,
        req.id,
        'Status is active but a "superseded-by" relation is recorded',
      );
    }
  }

  checkCycles(byId);

  /*
   * Code -> requirement: the other direction of 29148 traceability.
   *
   * A citation naming an ID that no longer exists is the same silent rot as a
   * requirement naming a test that no longer exists, pointed the other way — and
   * until now only one of the two was checked.
   *
   * Citing a superseded or withdrawn requirement warns rather than fails: it is
   * legitimate while the code still implements the old behaviour and the
   * migration has not happened yet. What is not acceptable is for it to be
   * invisible.
   */
  const citations = collectCitations();
  for (const { file, line, id } of citations) {
    const cited = byId.get(id);
    if (!cited) {
      fail(`${file}:${line}`, id, 'cites a requirement that does not exist');
      continue;
    }

    const citedStatus = first(cited.fields.Status ?? []);
    if (citedStatus === 'superseded' || citedStatus === 'withdrawn') {
      warn(`${file}:${line}`, id, `cites a ${citedStatus} requirement`);
    }
  }

  // Indexes are only worth generating from a sound set; a graph built from
  // broken input would just be a second, prettier wrong answer.
  if (errors.length === 0) {
    for (const dir of dirs) {
      const expected = buildIndex(dir, requirements, byId);
      const indexPath = join(dir, 'index.md');
      const actual = existsSync(indexPath)
        ? readFileSync(indexPath, 'utf8')
        : null;

      if (WRITE) {
        if (actual !== expected) {
          writeFileSync(indexPath, expected);
          console.log(`wrote ${relative(ROOT, indexPath)}`);
        }
      } else if (actual !== expected) {
        fail(
          relative(ROOT, indexPath),
          null,
          'index is stale — run `yarn requirements:build`',
        );
      }
    }
  }

  if (warnings.length > 0) {
    console.warn(`\n${warnings.length} requirement warning(s):\n`);
    for (const warning of warnings) console.warn(`  ! ${warning}`);
    console.warn('');
  }

  if (errors.length > 0) {
    console.error(`\n${errors.length} requirement problem(s):\n`);
    for (const error of errors) console.error(`  ✗ ${error}`);
    console.error('');
    process.exit(1);
  }

  console.log(
    `requirements ok — ${byId.size} requirement(s) across ${dirs.length} area director${dirs.length === 1 ? 'y' : 'ies'}, ${citations.length} citation(s) in code`,
  );
};

// Run when invoked as a script. A test imports the helpers without running this.
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main();
}
