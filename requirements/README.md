# Requirements

Requirements are **artefacts in this repository**, not prose in a wiki and not
sentences buried in `CLAUDE.md`. They are normative: code, tests and review
answer to them.

This system follows **ISO/IEC/IEEE 29148:2018** (*Systems and software
engineering — Life cycle processes — Requirements engineering*, which
superseded IEEE 830) for the attribute set, the requirement characteristics and
the `shall` convention. Statement grammar is **EARS**. Supersession follows
**IETF RFC 2026**'s `Obsoletes`/`Updates` model. The relation vocabulary is
trimmed from **SysML**.

## Why the ceremony exists

`REQ-CHIPS-001` in `seanmizen/seanorepo` is the worked example, and it is also
the reason for all of this. It existed only as a code comment. In
seanorepo#197 the status chips were moved
into the site header's normal flow to resolve a layout collision — **silently
dropping a stated requirement**, because nothing anywhere recorded that it was
one. seanorepo#198 reverted the change and added tests so the same trade cannot be made
again without a test going red and someone having to argue for it.

A requirement that is not written down can be traded away by accident. A
requirement with no verification is a wish. This system exists to close both
gaps, and nothing more.

---

## Where requirements live

**One file per requirement *area*. The ID prefix is the filename.**

```
requirements/                    # monorepo-wide constraints
  README.md                      # this file
  index.md                       # GENERATED — do not edit
  <prefix>.md                    # e.g. platform.md holds REQ-PLATFORM-*

apps/<app>/requirements/         # app-level requirements
  index.md                       # GENERATED — do not edit
  <prefix>.md                    # e.g. chips.md holds REQ-CHIPS-*
```

The checker finds a `requirements/` folder at any depth under `apps/` and
`utils/`, e.g. `apps/<app>/requirements/`. It skips every
`archive/` directory, for requirements and for citations. Retired work does not
count.

`REQ-NAV-014` is in a file named `nav.md`. That is a string rule, not a lookup:
an agent following a relation reads the ID, derives the filename, and opens it.
No index, no grep, no tooling. The prefix registry below says which level a
prefix lives at.

Areas group requirements that constrain **each other**, so reading one file
gives you the local dependency graph for free. This is deliberately not one
file per requirement: an agent working a navigation ticket wants all the
navigation requirements together, not six file reads and an index to know which
six.

### Prefix registry

Prefixes are globally unique. Add a row when you add a file.

| Prefix | File | Scope |
|---|---|---|
| `A11Y` | `requirements/a11y.md` | Access for assistive technology (screen readers) to a swindowzig UI |
| `ASSETS` | `requirements/assets.md` | Data from `sw_assets`: zip archives, files from the player and the data cache |
| `AUDIO` | `requirements/audio.md` | Sound output from `sw_audio`: the waveform API, samples, streams, the mixer and 3D sound |
| `CAMERA` | `requirements/camera.md` | The camera controller of `sw_math`: modes, smoothing, field of view |
| `DEMO` | `requirements/demo.md` | The showcase demos in `demos/`: scripts, frame hashes and recordings |
| `GPU` | `requirements/gpu.md` | Textures, samplers and other resources of `sw_gpu` |
| `INPUT` | `requirements/input.md` | Keyboard, mouse, wheel and gamepad input from the platform backends |
| `NET` | `requirements/net.md` | The WebSocket client of `sw_net`: events, frames and the reconnect |
| `PLATFORM` | `requirements/platform.md` | The window, the cursor and the clipboard from the platform backends |
| `TEXT` | `requirements/text.md` | Shaping, measuring and caret geometry of the text from `sw_text` |
| `VOXEL` | `requirements/voxel.md` | Chunk storage, meshing and the chunk pipeline of `sw_voxel` |

---

## Anatomy of a requirement

````markdown
## REQ-CHIPS-001 — Chips are fixed-position chrome

- **Status:** active
- **Source:** sean
- **Origin:** #198
- **Type:** constraint
- **Priority:** P2
- **Statement:** The status chip stack shall be rendered as fixed-position
  chrome, outside normal document flow.
- **Rationale:** Why this is required, and what went wrong without it.
- **Verification:** Test — `path/to/spec.ts` › "the test name"
- **Relations:** none
````

Every field is required. A field's value may continue onto following lines
indented by two spaces. `Verification` and `Relations` may instead be a nested
list when there is more than one entry.

### Fields

| Field | Meaning |
|---|---|
| **Status** | `proposed` · `active` · `superseded` · `withdrawn` |
| **Source** | *Who asserted this.* `sean`, or `agent:SWZ-197` for one an agent derived while working a ticket. |
| **Origin** | Where it was decided — an issue or PR reference. |
| **Type** | `functional` (behaviour) · `constraint` (a bound on the solution) · `quality` (a non-functional characteristic, per ISO/IEC 25010) |
| **Priority** | `P0`–`P3`, the same scale the issue tracker uses. |
| **Statement** | The requirement itself, in the grammar below. |
| **Rationale** | Why it is required. 29148 treats intent as part of the requirement — without it, a later worker cannot tell a load-bearing constraint from an arbitrary one. |
| **Verification** | How it is proven, and where. |
| **Relations** | Links to other requirements, or `none`. |

**`Source` matters more here than in a conventional codebase.** Agents write
prose into this repo. Attribution is what separates a decision Sean locked from
an assumption an agent inferred mid-ticket — and without it the second kind
hardens into the first.

### Statement grammar

29148 reserves **`shall`** for requirements (`should` is a goal, `may` is
permission, `will` is a statement of fact). Exactly one `shall` per requirement
— that is 29148's *Singular* characteristic, and the validator enforces it. If
you need two, you have two requirements.

EARS supplies five patterns:

| Pattern | Form |
|---|---|
| Ubiquitous | The `<system>` shall `<response>`. |
| Event-driven | When `<trigger>`, the `<system>` shall `<response>`. |
| State-driven | While `<state>`, the `<system>` shall `<response>`. |
| Unwanted behaviour | If `<trigger>`, then the `<system>` shall `<response>`. |
| Optional feature | Where `<feature>`, the `<system>` shall `<response>`. |

### Verification

29148's four methods. Name one, then say where it lives.

| Method | Use for |
|---|---|
| `Test` | An automated test. **Preferred** — link the spec file and the test name. |
| `Analysis` | Proven by reasoning over the code, e.g. a type-level guarantee. |
| `Inspection` | Confirmed by reading the artefact, e.g. a config file's contents. |
| `Demonstration` | Shown by operating the system, where nothing else fits. |

A `Test` link must point at a file that exists — the validator opens it. A test
renamed or deleted out from under a requirement turns CI red, which is the
whole point.

`Test` and `Inspection` links follow the same rule, plus one more. Write the
path from the repo root. The file has to sit inside the **unit** that owns the
requirements folder, which is the folder's parent: `apps/<app>/` for
`apps/<app>/requirements/`. No link may point into `archive/`. So one
generation's requirements cannot be met by another generation's code. The root
`requirements/` folder's unit is the whole repo.

A `Test` cites the first path in backticks. An `Inspection` cites the first
backticked repo path, so it may name a setting or a host path such as
`/usr/local/lib/systemd/system` first. An `Inspection` with no repo path
inspects the running system and is not checked.

### Relations

Six, with inverses. Keep the vocabulary small so an agent can hold it.

| Relation | Inverse | Means |
|---|---|---|
| `depends-on` | `required-by` | Cannot be satisfied unless the target is. Must not form a cycle. |
| `refines` | `refined-by` | Narrows a broader parent requirement. |
| `conflicts-with` | `conflicts-with` | A real tension. Both stay; the resolution is recorded in `Rationale`. |
| `supersedes` | `superseded-by` | Replaces the target entirely (RFC `Obsoletes`). |
| `amends` | `amended-by` | Modifies the target; **both stay in force** (RFC `Updates`). |
| `verified-by` | — | Points at another requirement whose verification also covers this one. |

---

## Changing a requirement

**Requirements are never deleted, and an issued ID is never reused or renamed.**
This is why prefixes can never be reorganised into tidier groupings later, and
why a file holding three requirements is fine.

Editing in place is allowed **only** for things that do not change meaning:
fixing a typo, correcting a broken `Verification` path, adding `Rationale`.

To change what a requirement actually demands, add a new one:

- **Superseding** — the old requirement is wholly replaced. The new one gets
  `supersedes REQ-X-001`; the old one's `Status` becomes `superseded` and it
  gains `superseded-by REQ-X-014`. The old text stays exactly as it was.
- **Amending** — the old requirement still holds, with a modification. The new
  one gets `amends REQ-X-001`; the old one stays `active` and gains
  `amended-by REQ-X-014`.
- **Withdrawing** — no longer wanted, and nothing replaces it. `Status` becomes
  `withdrawn` and `Rationale` gains a line explaining why. It stays in the file.

A superseded requirement is still readable history. It explains why the code
looks the way it does, and stops a later worker re-proposing something already
tried and rejected.

---

## Commands

```bash
yarn requirements:check    # validate; fails if anything is wrong or an index is stale
yarn requirements:build    # regenerate every index.md
```

CI runs `requirements:check` on every PR. If it fails on a stale index, run
`yarn requirements:build` and commit the result — an `index.md` is generated
and must never be hand-edited.

### What the check enforces

Both directions of traceability, because checking only one leaves the same rot
free to happen the other way round:

| Direction | Rule |
|---|---|
| requirement → test | A `Verification` link of method `Test` must name a file that exists, inside its unit and outside `archive/`. So must an `Inspection` link that names a repo path. A spec renamed out from under a requirement turns CI red. |
| code → requirement | Every `REQ-...` cited anywhere outside `requirements/` must be a declared ID. A citation of a **superseded** or **withdrawn** requirement warns instead of failing — legitimate while the code still implements the old behaviour, but never invisible. |

Plus, on the requirements themselves: ID format and prefix/filename agreement,
unique IDs, required fields, the one-`shall` Singular rule, EARS clause
structure, relation vocabulary and targets, `depends-on` cycles, and
supersession recorded on both sides.

Failures name `file:line`, so a broken citation says exactly where it is.

## Referring to requirements from code

Cite the ID in a comment where a requirement constrains the code, so the next
reader — human or agent — knows the shape is deliberate:

```ts
// Floating chrome on every route — see REQ-CHIPS-001.
```

Citations are checked: an ID that does not exist fails CI, and one naming a
superseded or withdrawn requirement warns. So cite freely — a stale reference
reports itself rather than quietly misleading the next reader.

`CLAUDE.md` files keep their prose and gain the ID alongside it. The prose
explains; the requirement binds.
