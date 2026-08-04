# Vocoder Constitution — translate-action

<!--
  GENERATED REGION. Do not edit between the STAMPED markers.
  Source: ../../CONSTITUTION.md   Hash: fbc3f092fbb4b1ac1a5224f9cce351178809278beba184253655cb1b2a74299b
  Regenerate: ./scripts/sync-constitution.sh
  Repo-specific rules belong in the LOCAL region at the bottom of this file.
-->

<!-- STAMPED:BEGIN -->
<!-- hash: fbc3f092fbb4b1ac1a5224f9cce351178809278beba184253655cb1b2a74299b -->

## 2. Core principles

1. **Done is computed, never asserted.** An agent may not declare work complete. The gate script's exit code decides.
2. **Every acceptance criterion is machine-checkable.** A criterion that cannot be tied to a passing test is not a criterion — it is a wish. Rewrite it or drop it.
3. **Evidence ships with the work.** Test output, Playwright traces, and screenshots accompany every PR. Reviewers read evidence, not assertions.
4. **Small, single-repo, single-purpose changes.** One ticket, one branch, one repo, one PR.
5. **Static analysis is not verification.** Reading code proves it exists, not that it works. Claims of behavior require execution.
6. **Proportionality.** Rigor scales with risk and surface area. A README fix does not need an E2E spec. Anything touching money, auth, or customer data does.
7. **There are no users yet.** Vocoder is pre-launch. Nothing is deployed, nothing is depended on, and no customer data exists. **Build the right thing, not the compatible thing.**

## 2.1 Pre-launch stance

This is the single most important context for every decision, and it holds until Eric says otherwise.

**No backward compatibility. Ever, for now.** There is nobody to break.

- Rename anything. Schemas, columns, types, exports, routes, CLI flags, config keys.
- Delete dead code and abandoned approaches outright. Do not leave them "just in case".
- No deprecation paths, no compatibility shims, no aliases, no `@deprecated` markers, no dual-write migrations, no version negotiation.
- Breaking changes to published SDK packages are **normal and expected**. Bump the version and move on.
- Do not preserve an existing design merely because it exists. If the current shape is wrong, change it.
- Do not ask permission to make a breaking change. Correctness is the standard; compatibility is not a consideration.

**What this does not excuse.** Some care is unrelated to users:

- Eric's own local and preview data is real and must not be destroyed (§13)
- Provider API calls cost real money whether or not anyone is watching
- Secrets are secrets regardless of traffic
- Migrations must still be correct, because the databases that exist are the ones being worked in

When flagging risk, ask *what actually breaks* — not *what would normally be risky in a mature product*. "This changes a published export" is not a risk today. "This could double-charge provider calls" is.

---

## 3. Readiness rubric

Every surface and capability is scored on this scale. The score is a claim about **evidence available**, not effort spent.

| Level | Meaning | Required evidence |
|---|---|---|
| **L0** | Schema/type only | — |
| **L1** | Logic implemented, unit tested | passing unit test |
| **L2** | API/tRPC wired; permission + plan gates enforced | passing test exercising gates |
| **L3** | UI built and bound to the API | code review |
| **L4** | Verified against real DB and/or live providers | passing integration test |
| **L5** | End-to-end: happy path **and** empty **and** error states | Playwright trace or video |
| **L6** | Manually exercised by a human | screenshots, dated |

A level is only claimable when every level beneath it also holds.

### 3.1 MVP bar

| Category | Required |
|---|---|
| User-facing screens in MVP scope | **L5** |
| Pipeline / worker / cron | **L4** |
| Admin-only screens | **L4** |
| Public SDK packages | **L4** + published-artifact smoke check |
| Marketing, docs, legal, copy | **L3** + human read-through |

Anything below its bar is not MVP-complete, regardless of how finished it looks.

---

## 4. Definition of Done

A ticket is Done only when **all** applicable rows pass. Non-applicable rows are marked N/A in the PR with a one-line reason.

### 4.1 Universal

- [ ] Build succeeds
- [ ] Typecheck: zero errors
- [ ] Unit tests pass
- [ ] Lint/format clean on touched files
- [ ] Every acceptance criterion maps to a named passing test
- [ ] No secrets, keys, or `.pem` files added
- [ ] Docs updated where the change makes existing docs untrue
- [ ] Comments follow §4.1.1

#### 4.1.1 Comments and documentation

**Document what exists. Never document what changed.**

Comments and docs describe the system as it is now, to a reader who has never seen any earlier version. There is no length limit — write what a reader needs.

**Forbidden: change-relative language.** A comment must not reference what the code used to do, what it replaced, why it was changed, or that it changed at all. That belongs in the commit message and the PR, which is where history is actually queryable.

```ts
// ✗ describes an edit — meaningless to anyone reading this file next year
// Previously unbounded; added a cap to prevent oversized payloads
// Changed from 4000 to 10_000 after the billing audit
// NOTE: no longer uses the old resolveKey path
text: z.string().trim().min(1).max(10_000),

// ✓ describes the system — true regardless of how it got that way
// 10K covers any realistic UI string; the cap bounds the payload a single
// oversized entry can send to the provider.
text: z.string().trim().min(1).max(10_000),
```

The same rule governs JSDoc, README sections, and doc files: no "now uses", no "previously", no "was renamed from", no migration narration.

**Applies to agents especially.** An agent that just made a change is primed to explain the change. Explain the code instead.

Everything else — how much to write, JSDoc coverage, house style — is owned by the repo docs (§15), not restated here.

#### 4.1.2 Derive from the source of truth

**Never restate a value that already exists as an enum, constant, type, or config entry. Import it.**

A restated value is a silent fork. It compiles, it passes tests, and it drifts the moment the original changes — with nothing to catch it.

```ts
// ✗ string literal where a Prisma enum exists
provider: params.provider ?? "DEEPL",
status: { in: ["PENDING", "TRANSLATING"] },

// ✓
provider: params.provider ?? ProviderVendor.DEEPL,
status: { in: [BatchStatus.PENDING, BatchStatus.TRANSLATING] },
```

Applies to Prisma enums and model types, `billingConfig` plans and limits, `PERMISSIONS` features and actions, provider vendor and type identifiers, locale codes, and every route or env key that exists as a constant.

**Lists are derived, not hand-written.** A UI select, a test matrix, or a validation set that enumerates cases by hand drifts the moment a case is added. Iterate the source:

```ts
// ✗ hand-listed; a new vendor silently disappears from the UI
<SelectItem value="DEEPL">DeepL</SelectItem>
<SelectItem value="GOOGLE">Google</SelectItem>

// ✓ derived; a new vendor appears automatically
{Object.values(ProviderVendor).map((v) => <SelectItem key={v} value={v}>{label(v)}</SelectItem>)}
```

This is the same rule the repo already applies to tests — *"tests import the real config, never duplicate values"* — generalized to all code.

**Legitimate exceptions:** type-level literals that narrow a generic (`ConfigByType<"DEEPL">`), the definition site itself, and wire-format strings pinned by an external contract. When pinning an external value, say so in one line so the next reader doesn't "fix" it.

When a needed value has no constant, **create one** rather than inlining it twice.

### 4.2 If it touches the database

- [ ] Migration is timestamped `YYYYMMDDHHMMSS_name`
- [ ] Reference-data inserts are idempotent (`ON CONFLICT DO NOTHING`)
- [ ] Destructive schema changes are split across separate deploys
- [ ] Integration test covers the new behavior

### 4.3 If it touches a protected route or mutation

- [ ] Server-side permission check before render
- [ ] `RouteGuard` on the page
- [ ] `assertPermission` in the tRPC procedure
- [ ] Plan gate applied where entitlements govern access
- [ ] Test proves an unauthorized role is actually refused

### 4.4 If it touches user-facing UI

**States** — all four are required. A screen that only handles the success path is not done.

- [ ] Loading state implemented
- [ ] Empty state implemented
- [ ] Error state implemented
- [ ] Responsive at mobile and desktop widths
- [ ] Playwright spec covers happy path + empty + error

**Precedent** — new UI is derived from existing UI, never invented alongside it.

- [ ] Named the closest existing screen in the spec, and matched its layout, spacing, and interaction patterns
- [ ] Reused shared primitives rather than rebuilding them — `Page`/`PageBody`/`PageContent`, `DataTable`, `CompactStats`, `EmptyText`, `CenteredSpinner`, `UnderlinedTabs`, and the `@/components/ui/` set
- [ ] Modals go through `@ebay/nice-modal-react` with `useEnhancedModal`; destructive confirmations use `ConfirmationModal`
- [ ] Loading uses `Skeleton`, notifications use `toast` from `sonner`
- [ ] Icons from `lucide`; no second icon library
- [ ] No new one-off color, spacing, or typography value where a token exists
- [ ] A new shared primitive is justified in the PR, or the work reuses an existing one

Repo conventions are authoritative and live in `app/AGENTS.md` (Component Structure, UI Components, Modals & Dialogs, Forms) and `docs/BRAND_IDENTITY.md`. Read them before writing UI; this constitution does not restate them.

**Divergence** from an existing pattern is allowed but never silent — state it in the spec with a reason, before implementing.

### 4.5 If it changes published SDK behavior

- [ ] Changeset added (`pnpm changeset`) describing the change and bump level
- [ ] Bump respects the two-tier grouping — `cli`/`config`/`extractor`/`mcp`/`plugin` version together; `core` and `react` move independently
- [ ] Package README updated where the public API changed
- [ ] `main` remains publishable

Breaking changes are fine (§2.1) — take the `major` bump and describe it plainly in the changeset. Do not add aliases or deprecation shims to avoid one.

A PR that changes published behavior without a changeset ships an unreleasable `main`. Internal-only changes (tests, tooling, CI) need no changeset — say so in the PR.

### 4.6 If it changes a cross-repo contract

- [ ] Coupling map in the relevant `CLAUDE.md` consulted and honored
- [ ] Companion sub-issue opened for each affected repo
- [ ] Parent ticket lists the integration criteria

---

## 5. Acceptance criteria

Written on the Linear ticket, before any spec exists.

**Form:** `GIVEN <state> WHEN <action> THEN <observable outcome>`

Each criterion carries the name of the test that proves it. Where no test exists yet, the criterion names the test to be written.

```
AC1  GIVEN a member-role user
     WHEN they open /dashboard/workspace/settings
     THEN they are redirected to /dashboard
     → e2e/workspace/settings-permissions.spec.ts::member is redirected

AC2  GIVEN an org on the Free plan
     WHEN a translation batch requests an AI provider
     THEN the batch is rejected with PLAN_LIMIT
     → lib/translation/__tests__/provider-routing.test.ts::free plan blocks AI
```

**Rejected as criteria:** "works correctly", "looks good", "is performant", "handles errors gracefully". These are untestable and will be sent back.

---

## 6. Evidence

Every PR body contains:

1. Linear ticket link
2. Gate script output (pasted, not summarized)
3. Per-AC table: criterion → test name → pass/fail
4. Playwright artifacts for any L5 work — trace or video, plus a screenshot per state
5. Explicit list of DoD rows marked N/A, with reasons

A PR without evidence is not reviewable and will not be merged, including on the auto-merge tier.

---

## 7. Risk tiers and merge authority

Tiers exist to protect against **irreversible harm** and to reserve **decisions that are not an agent's to make**. They do not exist to protect against change itself — per §2.1, breaking things is not a risk right now.

Red has two independent triggers. Either one is sufficient.

### 7.1 Red — irreversible or expensive

- **Money.** Billing, credits, provider calls, anything that can spend.
- **Data loss.** Prisma migrations, destructive operations.
- **Security.** Auth, RBAC, secrets, key handling.

### 7.2 Red — not the agent's decision

Changes to the business itself, regardless of how small the diff is:

- `config/billing.config.ts` — plan definitions, prices, limits, feature gates, credit rates
- What is free versus paid; what any tier includes
- Provider routing policy that shifts unit economics, e.g. defaulting to AI where MT was the floor
- Public positioning and the pitch — what Vocoder claims to be
- MVP scope: what ships and what waits
- Customer-facing terminology

These are founder decisions. An agent may **propose** them, with reasoning and a recommendation, and must not enact them. Escalate as in §13.6 — a well-argued proposal is the deliverable, not a merged change.

### 7.3 Green — everything else

Docs, copy, legal, blog, tests, lint and format, READMEs, examples, dependency bumps, refactors, renames, breaking API and schema shape changes, public SDK surface changes.

Ask **what actually breaks if this is wrong**, and **whose call is this**:

- *Costs money, corrupts data, exposes secrets* → Red
- *Changes the business, the pricing, or the pitch* → Red
- *Merely changes shape, name, or public surface* → Green. There are no users.

Unsure → Red. But "it changes a published export" or "it renames a field" is not, by itself, a reason for uncertainty.

npm publishes and `preview` → `main` promotion remain Eric's per §8.0, independent of PR tier.

### 7.4 Decision points — ask at implementation time, not at review time

The PR tier is a **fallback**, not the mechanism. By the time a §7.2 decision reaches review it has already been built, and Eric is reviewing a fait accompli instead of making a choice.

**When an agent hits a §7.2 trigger mid-implementation, it stops there.** Not after finishing. Not "implemented both ways for comparison." Stop at the fork.

Then, in this order:

1. **Send a `PushNotification`.** Always call it — the tool suppresses itself when Eric is at the terminal, so never try to guess whether he is present. One line, under 200 characters, naming the actual decision. `"pricing: gate glossary to Pro or leave on Starter?"` — not `"need your input"`.
2. **Ask a structured question** (`AskUserQuestion`) with 2–4 concrete options, recommended option first.
3. **Wait.** Do not proceed on an assumption. Do not pick the reversible-looking option to keep moving.
4. **Park and switch.** If no answer comes, move to unrelated work rather than idling or guessing. Leave the ticket in place with the open question recorded on it.

**Every decision point must contain all four:**

| Element | Means |
|---|---|
| **Where we are** | The specific code, file, and task that surfaced this. Enough context to answer without re-reading the ticket. |
| **Why this is yours** | Which §7.2 category it falls under, and what makes it a business decision rather than a technical one. |
| **The options** | Each with its concrete implication — what it costs, what it forecloses, what it commits to. Not a list of names. |
| **The recommendation** | A specific pick, with reasoning. Never present options neutrally and wait to be told. |

State implications in terms of consequence, not category: *"routes ~40% more strings to LLMs, roughly 3× the per-string cost, better output on prose"* — not *"may affect pricing."*

Record the answer on the Linear ticket and in the PR description, so the decision has a durable home and is not relitigated later.

This applies equally when the fork appears during a Green-tier ticket. Tier is assigned per ticket; **decision points are recognized per moment.** A docs PR that turns out to require deciding what a plan includes has hit §7.2, and the ticket's Green label does not override that.

`preview` → `main` promotion is **always Eric's decision**, in every case, without exception.

---

## 8. Branch and PR workflow

### 8.0 Integration target and promotion event

Every repo has an **integration target** (where finished work lands, continuously) and a **promotion event** (what exposes it to the world). Agents merge into the integration target. **The promotion event is always Eric's, in every repo.**

| Repo | Branch from | Integration target | Promotion event | Exposes |
|---|---|---|---|---|
| `app` | `preview` | `preview` | PR `preview` → `main` | Render production deploy |
| `sdk` | `main` | `main` | `changeset version` + `pnpm release` | npm packages |
| `translate-action` | `main` | `main` | git tag / `v1` move | GitHub Action consumers |

`sdk` has no preview branch and does not need one. A library has no deploy target; its release gate is changesets, which accumulates unreleased changes on `main` until a publish is deliberately cut. Adding a second branch would be ceremony with nothing behind it.

The consequence: **`sdk`'s `main` must be publishable at all times**, because a release cuts straight from it. A red `main` in `sdk` is as serious as a red `main` in `app`.

- One ticket → one branch → one repo → one PR

**Branch and spec naming.** The Linear ticket number *is* the Spec Kit feature number, zero-padded to three digits. `VOC-5` becomes branch `005-<slug>` and spec directory `specs/005-<slug>/`.

Create the feature with the ticket number pinned, never auto-numbered:

```
.specify/scripts/bash/create-new-feature.sh \
  --number <linear-ticket-number> \
  --short-name "<slug>" \
  "<ticket title>"
```

This keeps ticket ↔ branch ↔ spec directory ↔ PR traceable in both directions with no bookkeeping. Never let Spec Kit auto-assign a number — auto-numbering counts spec directories, which silently diverges from Linear the moment a ticket is created out of order or abandoned.
- Target: `preview` for app; `main` for sdk and translate-action

### 8.1 Size

There is no PR size limit. A PR is as large as the task legitimately requires. Doing the task correctly and completely outranks keeping the diff small — do not split work in ways that ship a screen without its states, or a change without its tests, merely to reduce line count.

### 8.2 Substance

Size has no floor either, but **significance does**. A PR delivers one complete, independently valuable unit of work — a feature, a bug fix, a coherent refactor, a documentation set. Not a step inside one, and not a stray edit.

The test: can the change be stated as an outcome someone cares about?

- "Replace starter-kit docs with real Vocoder documentation" — yes
- "Fix typo in README" — no
- "Add empty and error states to the translations page" — yes
- "Rename one variable" — no

**No PR without a Linear ticket.** If a change does not justify a ticket, it does not justify a PR.

### 8.3 Incidental fixes

Trivia discovered mid-ticket — a typo, a stale comment, a dead import — is handled in this order:

1. **Related to the work in hand?** Fold it into the current PR. Do not defer it.
2. **Unrelated?** Add it to the standing housekeeping ticket for that repo. It ships with the next batch.
3. **Never** open a PR for it on its own.

A housekeeping batch must stay coherent — related cleanups that can be reverted as a unit. It is not a junk drawer; bundling eight unrelated changes means one bad change forces reverting all eight.

**Substantial out-of-scope findings** — a real bug, a security issue, a missing capability — get their own ticket and their own PR. Those are not trivia, and folding them into unrelated work hides them.

### 8.4 Stacked PRs

A PR may be based on another open PR's branch when the work genuinely depends on it. Two rules, both learned the hard way.

**Never delete a base branch while a PR still targets it.** GitHub auto-closes any PR whose base branch is deleted, and a closed PR with a missing base can be neither reopened nor retargeted. The PR is simply dead.

Merge a stack bottom-up, and for each merge either:

- retarget every dependent PR to the new base **first**, then merge with `--delete-branch`, or
- merge **without** `--delete-branch` and clean up branches once the whole stack has landed

Recovery, if it happens anyway: the head branch survives, so rebase it onto the new base and open a fresh PR. The abandoned PR stays in the history as noise.

**Never stack a Green PR on a Red one.** The Green PR becomes unmergeable until Eric reviews the Red one, which defeats the point of tiering — work that needed no review ends up waiting for review anyway. If a Green change depends on a Red change, either wait and branch from the integration target after the Red one lands, or scope the Green work so it does not depend on it.

**Never:** commit to `main` directly; force-push a shared branch; rewrite pushed history; merge a PR whose gate is red.

---

### 8.5 Spec-driven execution — the skills, literally

**An agent never writes its own plan for a ticket.** Planning happens through the Spec Kit skills, invoked by name, in order. Producing a document that *looks like* a spec, a plan, or a task list — without running the skill that generates it — is a violation, not a shortcut.

Required order, every ticket:

| Step | Skill | Produces |
|---|---|---|
| 1 | `speckit-specify` | `spec.md` |
| 2 | `speckit-clarify` | resolved ambiguities, recorded |
| 3 | `speckit-plan` | `plan.md` |
| 4 | `speckit-tasks` | `tasks.md` |
| 5 | `speckit-implement` | the change |

`speckit-analyze` and `speckit-checklist` are optional and encouraged. `speckit-clarify` is **not** optional — it is the step that surfaces the questions an agent would otherwise answer by assumption.

Create the feature with the ticket number pinned (§8.0), so the artifacts land in `specs/NNN-<slug>/`.

**Sessions run from the workspace root.** The Spec Kit skills are installed at `vocoder-i18n/.claude/skills/` so they load there; `app/` and `sdk/` keep their own copies for anyone working inside a single repo.

Skills describe paths relative to a repo — `.specify/scripts/…`, `.specify/memory/constitution.md`, `specs/NNN-<slug>/`. **Resolve every one of them against the ticket's target repo**, not the working directory. A ticket names its repo; the sub-issue split in §9 guarantees exactly one.

Never require a human to move, restart, or relocate a session so an agent can proceed. If tooling only works from somewhere else, move the tooling.

**Why literally.** The skills carry templates, prompts, and gates that a hand-written approximation drops silently. An agent improvising a "spec" produces something shaped like the artifact while skipping the thinking the artifact exists to force — and the result is indistinguishable at review time. Anything that skips the skill also skips the mandatory review gates between spec, plan, and tasks.

**No implementation without artifacts.** `spec.md`, `plan.md`, and `tasks.md` must exist for the ticket before any code is written. A PR whose spec directory is missing or was authored by hand is rejected regardless of whether the code is correct.

**Exempt:** trivial fixes that would not justify a ticket (§8.2), and work batched into a standing housekeeping ticket (§8.3). If it earns a ticket, it earns the full cycle.

### 8.6 Model selection

Planning and implementation ask different things of a model. Reasoning matters most while the shape of the work is undecided; once `tasks.md` exists, the work is mechanical execution against a written plan.

| Phase | Model |
|---|---|
| `speckit-specify`, `clarify`, `plan`, `tasks`, `analyze` | **Opus** — the reasoning is the product |
| `speckit-implement` and the code it writes | **Sonnet** — the plan already exists |
| Reviewing evidence, resolving a §7.4 decision point | **Opus** |

Implementation runs through the `implementer` agent (`.claude/agents/implementer.md`), which pins Sonnet in its own definition. Planning stays on the main thread.

This is a convention, not a mechanism: skills cannot declare a model, and the Spec Kit workflow has no per-step model field. The agent boundary is the only real enforcement point, so **when in doubt, delegate implementation rather than continuing inline.**

Escalate back to Opus at any point if implementation reveals the plan was wrong. A plan that does not survive contact is a §7.4 decision point, not something to improvise past.

### 8.7 Closing a ticket, and picking up the next

Every ticket ends with the same three steps. They are not optional and they are not part of `tasks.md` — they run after the last task, on every ticket.

**1. Confirm the work actually landed.** Opening a PR is not finishing. Watch CI; if it is green and the ticket is Green tier, merge it. Then verify the merge: check the target branch contains the commits, and that the branch is still green afterwards. A PR that merged into a red `preview` is not done.

**2. Update Linear.** Move the ticket to its true state — `Done` when merged, `In Review` when awaiting Eric on a Red-tier PR. Attach the PR link. If the work revealed something the ticket did not anticipate, record it on the ticket rather than in a commit message nobody will search.

**3. Take the next ticket, or stop.**

The next ticket is **the highest-priority issue in `Todo`**. `Todo` means Eric has authorized it; `Backlog` means he has not. An agent never promotes a ticket out of `Backlog`, and never reorders the queue — choosing what to build next is a §7.2 decision.

**Stop and report instead of continuing when any of these hold:**

- `Todo` is empty
- The next ticket is **Red tier** — it needs Eric before work starts, not just before merge
- The next ticket carries an unresolved question, or `speckit-clarify` surfaces one that Eric must answer
- Any gate failed, or the previous merge left the target branch red
- **Five tickets have completed in one unbroken chain** — stop, summarize, let Eric redirect

The chain exists so work does not idle waiting for someone to say "next." It is not a mandate to keep going. A chain that stops early with a clear report is working correctly.

**Notify on stop** via `PushNotification` (§7.4) — one line naming why the chain ended and what is waiting.

## 9. Cross-repo work

A change spanning repos becomes:

- **Parent ticket** — the outcome, plus integration acceptance criteria
- **Sub-issue per repo** — each with its own spec, branch, and PR

The parent closes only when every sub-issue has merged **and** the integration criteria pass. Consult the coupling map in the relevant `CLAUDE.md` before opening the parent; it enumerates the known contracts and is authoritative.

---

## 10. Commit identity

- Author: `Vocoder Admin <admin@vocoder.app>` in every Vocoder repo. Never the personal account.
- **No AI attribution.** No `Co-Authored-By: Claude`, no "Generated with Claude Code" footers, in commits or PR bodies.
- `gh` operations run under the `vocoder-admin` account via `GH_CONFIG_DIR`.
- Freshly cloned repos inherit the personal global identity — set it locally before the first commit.

---

## 11. Parallel agents

Multiple agents may work simultaneously under these conditions:

1. **One worktree per ticket.** No two agents share a working directory.
2. **Isolated database per worktree.** A dedicated Neon branch, torn down when the worktree closes. Agents never share the local Postgres for integration or E2E runs.
3. **Isolated ports.** The dev server and Playwright `webServer` read their port from the environment.
4. **Non-overlapping scope.** Two tickets that edit the same files do not run concurrently. Sequence them.
5. **No agent merges another agent's PR.**
6. Rebase on the target branch before opening a PR; the gate must pass *after* the rebase.

---

## 12. The gate

Each repo exposes `./scripts/verify.sh`. It is the sole arbiter of Done.

It must:

1. Verify the stamped constitution block matches this file's hash
2. Run build, typecheck, lint, unit tests
3. Run integration tests when the change touches DB, providers, or API
4. Run Playwright specs for the touched surface when the change touches UI
5. Assert every acceptance criterion resolves to a passing test
6. Emit the evidence block for the PR body
7. Exit non-zero on any failure

Agents run the gate. Agents do not interpret it. A red gate means not done — never "done with a caveat".

---

## 13. Destructive actions

### 13.1 The principle

> **If an action cannot be undone in 60 seconds, take a snapshot first or get explicit approval.**

This governs regardless of whether the specific command appears on any list. There is no enumeration of forbidden commands here, deliberately: a list implies everything absent from it is safe, and the dangerous command is usually the one nobody anticipated.

Danger is a property of consequences, not of syntax. Most data loss comes from a routine command run with missing context — `docker compose down -v` to fix a stuck container, `db:push` against the wrong `DATABASE_URL`, `prisma migrate reset` to clear drift, `pnpm clean` (which is `git clean -xdf`). Each is the documented fix for some problem. None announce themselves as destructive.

**Before any operation that deletes, overwrites, resets, or drops:** state what is being destroyed, confirm it is recoverable, and say where the recovery copy is.

### 13.2 Snapshot before mutate

Non-negotiable, and framed as something to do rather than avoid:

- Dump a database before restoring, migrating destructively, or resetting it
- Copy a file or volume before modifying it in place
- Confirm the snapshot is readable before proceeding — an unverified backup is not a backup
- Record the snapshot's location in the PR or session output

### 13.3 Production is off-limits

- Agents never hold production credentials. An agent's environment must not be able to reach `vocoder-prod`.
- No agent runs migrations, resets, or schema changes against production or preview databases. Deploys apply migrations; agents do not.
- Production data is never copied to a local or shared environment.

### 13.4 Managed-infrastructure tools

Destructive operations exposed by MCP servers — Neon (`delete_project`, `delete_branch`, `reset_from_parent`), Render, Cloudflare, Stripe — are **never invoked autonomously**. Ask first, every time, including when the target looks disposable.

Creating and deleting an agent's *own* ephemeral Neon branch (per §11) is exempt, provided the branch was created by that agent for that ticket.

### 13.5 Irreversible git

Never force-push a shared branch, rewrite pushed history, delete a remote branch you did not create, or `git clean` a directory containing untracked work that has not been backed up.

### 13.6 Escalation

An agent blocked by this section stops and asks, following the decision-point protocol in §7.4 — notify, present options with implications, recommend, wait. It does not find a route around the constraint, and it does not proceed on the assumption that the action is probably fine. A blocked task reported honestly is a success; a completed task that destroyed data is not.
<!-- STAMPED:END -->

---

<!-- LOCAL:BEGIN -->
## Repo-specific rules

See `translate-action/CLAUDE.md` and `translate-action/AGENTS.md` for the authoritative repo conventions.
Add rules here that apply only to `translate-action` and are not covered by the stamped block.

Where a rule here conflicts with the stamped block, the stamped block wins;
raise the conflict as an amendment against the root CONSTITUTION.md.
<!-- LOCAL:END -->
