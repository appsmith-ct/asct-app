# M7 — Milestone loop and change requests

**Done 2026-11-20.** Spans both submodules.

Spec section 10, M7:

> Run milestones in order, demo pause after each, accept change requests only at milestone
> boundaries, re-run the SA on architecture impact and only the affected components.
> **Acceptance: a change request on milestone 1 output produces a new architecture version and
> re-runs only stale nodes.**

---

## What was built

### The loop (engine)

The project graph was a line (`ba -> sa -> build_milestone -> END`). It is now the cycle the
spec's mermaid diagram draws:

```
START -> ba -> sa -> build_milestone -> milestone_demo -> next_milestone -+
                          ^                                              |
                          +------------ sa_delta <- ba_change <-----------+
```

- **`milestone_demo`** (`graphs/milestone_flow.py`) writes a `MilestoneDemo` artifact: the
  milestone's own `demo_description`, the build's status, the staged components' URLs. It makes
  **no LLM call** — every field is something the engine already knows for certain, and asking a
  small model to restate them could only introduce error into the one screen whose job is telling
  the user the truth about what happened.
- **`next_milestone`** advances the cursor. It exists as a node rather than a state update folded
  into `milestone_demo` because the `after_milestone` gate needs a node boundary to interrupt
  *before*: the run has to be able to park with milestone N demoed and N+1 not yet started.
- **`ba_change` / `sa_delta`** (`graphs/change_request.py`) are the spec's "they go to the BA,
  then the SA re-evaluates the architecture and marks affected artifacts stale". Both are
  **no-ops when no change request is open**, so a project nobody gives feedback on walks the loop
  without paying for them. They delegate to the very same BA and SA nodes the first pass uses —
  only the artifact version they write differs — so there is exactly one place that knows how
  requirements and architectures are produced.

Two routing decisions close the loop, and both have a reason to exist:

- after `next_milestone`: continue if a change request is open (always — the user has just said
  the plan is wrong, and the BA may add a milestone in response), stop if the last milestone
  failed, otherwise continue while milestones remain.
- after `sa_delta`: a second decision, because `ba_change` can *add* a milestone — a change
  request raised at the final demo is the normal way that happens — so "is there anything left to
  build" can only be answered once the BA has re-run. It also returns true when the plan is
  exhausted but components are stale, which is the only way a change request raised at the last
  demo ever gets built.

### Milestone scoping (engine)

`graphs/milestone_scope.py`. A milestone's components are those whose `ComponentSpec` covers one
of its requirements, **closed over the component dependency graph** (derived from stored
`Contract`s: a consumer depends on its producer) and returned in dependency order. The closure is
not tidiness — QA tests the *staged system* over HTTP, so a frontend whose backend was never
started fails every check for reasons that have nothing to do with the milestone.

`milestone_build_scope` then unions in **every component currently marked stale**, wherever it
sits in the plan. Without that, a change request raised at milestone 1's demo that revises a
component milestone 2 doesn't touch would leave that component stale forever with its old code
shipped, because the loop never returns to milestone 1.

### Staleness and impact (engine)

- New `stale_artifacts` table (migration `b7c21a4d9e30`) plus
  `ArtifactStore.mark_stale`/`clear_stale`/`is_stale`/`list_stale`. It lives on the artifact store,
  not in run state, because the Artifacts screen renders stale markers and they have to outlive
  the process that marked them.
- New artifacts: `ChangeRequest` (the one artifact a human writes), `MilestoneDemo`,
  `ChangeImpact`.
- **Impact is computed by diffing stored `ComponentSpec`s**, ignoring envelope fields (version,
  created_at, produced_by, parent_ids) — never by asking the SA what it changed. The SA rewrites
  every component's spec on every run, so without the envelope filter every component looks
  changed and "re-run only the affected components" degenerates into "re-run everything", the
  exact outcome M7 exists to avoid. And a model's own report of its changes is a second thing to
  get wrong, expensively in both directions: a missed component ships stale code, a spurious one
  rebuilds a working component. The SA's prose reasoning is still recorded, as
  `ChangeImpact.rationale` — it just isn't trusted for control flow.
- `fan_out_components` skips a component that already has a `ComponentReport` and isn't stale.
  That's the "re-runs only stale nodes" half of the acceptance criterion, and it's what makes the
  loop affordable: milestone 2 shares most of its scope with milestone 1, and rebuilding finished
  components every milestone would multiply the project's cost by the milestone count.

### API, CLI, UI

- `POST /runs/{id}/control {"action": "change_request", "text": ...}` — **409 unless the run is
  parked at `after_milestone`**, which is the spec's "accepted only here" enforced at the only
  place it can be. Storing a request doesn't resume the run: a user may want to raise two before
  approving, and all open ones are applied together.
- `GET /runs/{id}/milestones` — the plan and progress, read from stored `MilestoneReport`s rather
  than run state, so it still answers after an engine restart.
- `GET /runs/{id}/artifacts` now carries `stale`/`stale_reason` per artifact.
- `appsmith change-request <project> "<text>"`, and `appsmith run` drives the full loop.
- UI: a Milestones panel on the Pipeline screen (`MilestoneRail`), the milestone demo pause with
  its change-request control (`MilestoneGate` — deliberately a different control from the plain
  gate banner: every other gate is a yes/no, this one is a conversation), and stale badges on the
  Artifacts screen.

---

## Three real bugs found and fixed

**1. A LangGraph conditional edge sees only the source node's annotated input schema.**
`next_milestone`'s node is annotated `MilestoneLoopNodeInput` (`project_id`, `milestone_index`),
so the router after it read `milestone_count` as `None` and ended every run after milestone 1 —
no exception, no warning, just a run that looked like it had finished. Confirmed as a general
LangGraph behaviour with a standalone reproduction (widen the source node's annotation and the
router's state widens with it) rather than worked around blindly. Fixed by making `has_more_work`
take explicit scalars and having the caller read them from the artifact store
(`milestone_loop_progress`), which also makes the decision reproducible after a restart.

**2. Per-round artifact versions collided across milestones.** `IntegrationReport`, `StagingReport`,
`TestPlan` and `QAReport` were versioned `round_number + 1`. With one milestone that was fine;
with the loop, milestone 2's round 0 asks for `IntegrationReport` v1, finds **milestone 1's**, and
short-circuits on it via the idempotent-skip — silently reporting milestone 1's integration result
as milestone 2's. Fixed with `round_artifact_version`, which carves the version space into a
`bugfix_rounds + 1` block per milestone: unique, a pure function of (milestone, round) so a
resumed run finds its own artifacts, and monotonic so version history reads in execution order.

**3. A stale component could never actually rebuild.** A finished component build leaves a
checkpoint at END, and re-invoking that thread returns the finished state without running anything
— the behaviour crash-resume depends on, and exactly wrong for a deliberate rebuild against a
revised spec. Fixed by putting each build version on its own checkpoint thread
(`<component_id>#v2`), with `artifact_version=1` reproducing the pre-M7 thread id exactly so
existing checkpoints keep resuming. The build version comes from counting finished
`ComponentReport`s, *not* the `ComponentSpec` version — a change-request pass rewrites every
component's spec including the untouched ones, so spec version is not a usable proxy for "needs
rebuilding".

Plus two UI bugs the screenshot pipeline caught that `pnpm build`/`pnpm lint` did not:

**4. `<ReactFlow fitView>` fits once, at mount.** The milestone gate banner appearing above the
canvas shrank the pane with no re-fit, leaving the nodes correctly rendered but scrolled clean out
of view — a blank dotted canvas that only came back on a page reload. Fixed with a `ResizeObserver`
on the pane, deferred one `requestAnimationFrame`. An effect keyed on `atMilestoneGate` was tried
first and doesn't work: it fires before the browser lays the new size out, so it re-fits to the
size it's trying to replace.

**5. The Artifacts screen's version picker was inert.** It called the artifact endpoint, which had
no `version` parameter and always returned the latest. Harmless while nothing ever had a v2 —
which M7 changes, turning it into a screen that shows the wrong data while looking right. Added
`?version=` and wired the picker to it.

---

## Scope notes

- **The `after_milestone` gate works by `interrupt_before=["next_milestone"]`, unchanged across
  invocations.** Verified empirically first: resuming a thread parked before an interrupt node
  runs that node and continues, interrupting again only the *next* time execution reaches it. M6's
  `_interrupt_nodes_for` carried an exclusion for the node a resume had just passed, on the
  opposite assumption — unnecessary then, and once the loop closed it would have silently disabled
  the milestone gate whenever the SA gate was approved. Removed.
- **`build_project_graph`'s loop nodes are optional.** Omitting them yields exactly the pre-M7
  linear graph. Not backwards compatibility for its own sake: several tests drive the three-node
  graph to assert on one milestone's behaviour in isolation, and a test that has to stand up the
  whole loop to check one node is a worse test.
- **A failed milestone stops the run** unless a change request is open. Spec section 10's wording
  is "reaches ready **or a clear failure report**"; grinding the next milestone onto a broken
  foundation produces neither.
- **`ScenarioFakeChatModel` returns the same content on every call**, so a change request raised
  against `appsmith serve --fake-llm` produces an architecture v2 identical to v1 and therefore no
  affected components. That's a property of the fake, not a gap in the flow — the engine test
  scripts a genuinely different second pass. Worth knowing before concluding from a manual
  fake-LLM session that change requests "don't do anything".
- **Per-milestone QA scoping is not special-cased.** QA writes its test plan from the project's
  requirements, not the current milestone's. The staged system only contains the milestone's
  components, so out-of-scope tests fail as connection errors rather than being skipped. Noted
  rather than fixed: it needs a QA context change, not a loop change.

---

## Acceptance verification

**The criterion, literally:**
`tests/test_milestone_loop.py::test_change_request_produces_a_new_architecture_and_rebuilds_only_the_affected`
— the real project graph, the real BA and SA against a scripted `FakeChatModel`, real
`milestone_demo`/`next_milestone`/`ba_change`/`sa_delta` nodes, a real `after_milestone` gate
pausing the run *between separate top-level invocations* (so the resume is genuine, not one long
in-process call), and a change request submitted while it's parked there. Asserts: Architecture
goes `[1] -> [1, 2]`; RequirementsArtifact likewise, with the new requirement present; the change
request is marked applied with a `ChangeImpact` naming `orders` changed and `reports` unchanged;
`orders` gets a second `ComponentReport` version while `reports` keeps one.

What's substituted is `build_and_verify_milestone` itself, through `make_build_milestone_node`'s
`build_fn` seam — the component build is M4/M5's territory, already covered end to end by their
slow tests with real git repos and real subprocess gates. M7's own logic is *which* components get
asked for, and that's exactly what the recorder observes.

**Supporting tests:** `test_milestones_run_in_order_with_a_demo_pause_after_each`;
`test_an_unaffected_component_is_not_rebuilt_by_a_change_request` (the negative half, past the last
milestone); `test_fan_out_components_skips_a_finished_component_but_rebuilds_a_stale_one` (the skip
decision one level down); `test_round_artifact_version_never_collides_across_milestones`;
`tests/test_milestone_scope.py` (6 tests: requirement intersection, transitive dependency closure,
dependency ordering, fallbacks); `tests/test_change_request.py` (8 tests, the important one being
that an identically-respec'd component is *not* classified as changed); four new API tests covering
the control action's acceptance, its 409 outside a milestone gate, its 422 on empty text, and the
milestones endpoint.

**Suites:** `uv run pytest` — **199 passed** (~107s, including every slow real-subprocess test);
`ruff check .` clean; `mypy appsmith` clean (66 source files). Frontend: `pnpm build` and
`pnpm lint` clean. `pnpm run e2e` — the Playwright smoke test, extended to drive the milestone demo
gate and submit a change request through the UI, passes against a self-started
`appsmith serve --fake-llm` + `vite` pair.

**Screenshots:** the milestone gate, the change-request control with CR-001 listed, and the
Artifacts screen showing `Architecture v2`, `ChangeImpact/CR-001`, `ChangeRequest/CR-001` at
`status: applied`, and `RequirementsArtifact v2` — all captured against a real running pair, which
is how bugs 4 and 5 were found.
