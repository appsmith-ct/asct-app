# Appsmith-CT — Build Progress

This is a living status tracker, updated as work happens, so progress survives context compaction across
Claude Code sessions. For what each milestone requires, see
`docs/specs/2026_11_13-appsmith_ct_implementation_specification.md`, section 10. For how a specific
milestone was executed, see the matching dated plan in `docs/plans/`.

Last updated: 2026-11-14

## Milestone status

| Milestone | Status | Plan doc |
| --- | --- | --- |
| M0: Skeleton | **Done** | `docs/plans/2026_11_13-m0-skeleton-plan.md` |
| M1: Engine foundation | **Done** | `docs/plans/2026_11_13-m1-engine-foundation-plan.md` |
| M2: Intake and BA | **Done** | `docs/plans/2026_11_13-m2-intake-and-ba-plan.md` |
| M3: Software Architect | **Done** | `docs/plans/2026_11_13-m3-software-architect-plan.md` |
| M4: Component subgraph | **Done** | `docs/plans/2026_11_14-m4-component-subgraph-plan.md` |
| M5: Integration, staging and QA | Not started | — |
| M6: API and UI | Not started | — |
| M7: Milestone loop and change requests | Not started | — |
| M8: Packaging and evaluation | Not started | — |

## M0 — detail

**Done 2026-11-13.** Three repos created and linked (`asct-app` root, `asct-be-engine` and
`asct-fe-desktop` as submodules, each pushed to the GitHub repos listed in `docs/github_links.md`). Engine
has a `uv`-managed FastAPI app with `GET /health` and a passing `pytest`/`ruff`/`mypy` setup; UI has a
`pnpm`-managed Vite/React/TypeScript scaffold with passing `pnpm build`/`pnpm lint`. CI workflows exist in
both component repos. Root `CLAUDE.md`/`README.md` and `scripts/dev.*`/`scripts/setup.*` are in place.

Full detail, including the one credential-setup snag (`gh auth setup-git`) and the deliberate
not-yet-built pieces (Tailwind, React Flow, Alembic, LangGraph — all scheduled for later milestones): see
`docs/plans/2026_11_13-m0-skeleton-plan.md`.

**Acceptance verification:** done. A fresh `git clone --recurse-submodules` of `asct-app` from GitHub into
a scratch directory, then `uv run pytest` in `asct-be-engine` and `pnpm install && pnpm build` in
`asct-fe-desktop`, both pass. M0 is fully closed out.

## M1 — detail

**Done 2026-11-13.** All in `asct-be-engine`. Config loader for `roles.yaml`-shaped config
(`ModelProfile`/`RoleConfig`/`Limits`/`RolesConfig`); two SQLite databases (per-user app/settings db,
per-project db), each with its own hand-written Alembic migration, run programmatically via
`appsmith/core/migrate.py`; `ArtifactStore` with versioned, idempotent saves plus a readable file
export; `FakeChatModel` (a real `BaseChatModel`, not a mock) and `LLMClient.generate_structured` with
constrained-decoding hints, Pydantic validation, bounded retry, and full call tracing to `llm_calls`;
a synchronous `EventBus` with the typed run-event vocabulary from spec section 9; the `ContextBuilder`
base class (whitelist filtering + budget-based trimming, loud failure on overflow); `appsmith config`
CLI standing in for the Settings screen; and a manual script to run the same LLM-call path against a
real local endpoint.

**Acceptance verification:** done. `tests/test_graph_resume.py` runs a two-node LangGraph under
`FakeChatModel`, writes a versioned artifact, and records the call; a second test simulates a crash by
rebuilding every in-memory object from scratch against the same on-disk databases and confirms no
duplicate LLM call or artifact version. Full suite: `uv run pytest` (28 passed), `ruff check .`
(clean), `mypy appsmith` (clean) — re-verified against a fresh `git clone --recurse-submodules` of
`asct-app`, not just the local working copy. `scripts/manual_m1_check.py` covers the real-endpoint
half of the acceptance criterion (human-run, not CI).

Full detail, including deliberate not-yet-built pieces (`run_agent_loop`, per-kind artifact export
paths, concrete ContextBuilder subclasses — all scheduled for M2+): see
`docs/plans/2026_11_13-m1-engine-foundation-plan.md`.

## M2 — detail

**Done 2026-11-13.** All in `asct-be-engine`. `ProjectBrief` (versioned Artifact, one version per
chat turn), `Requirement`/`Milestone` (plain records living inside new `RequirementsArtifact`/
`MilestonesArtifact` collection artifacts). Intake is a single-node LangGraph
(`appsmith/roles/intake.py`, `appsmith/graphs/intake_graph.py`) checkpointed per project directory —
confirmed empirically that a partial `invoke()` input merges with the prior checkpoint rather than
overwriting it, which is what makes a CLI process resumable across separate runs. BA
(`appsmith/roles/ba.py`) makes one LLM call per project; a Pydantic cross-reference validator
(every requirement's `milestone_id` must name a real milestone) reuses `LLMClient`'s existing
retry loop with no new machinery, and each milestone's `requirement_ids` is derived
deterministically rather than asked of the model, to avoid trusting a small model to keep two
lists in sync. Real system prompts (with worked examples) replace the M1 placeholders for both
roles. `appsmith chat <project>` and `appsmith run <project> --stop-after ba` round out the CLI.

Found and fixed a real `LLMClient` bug along the way: it called its `chat_model_factory` fresh on
every `generate_structured()` call, so a stateful `FakeChatModel` would silently replay its first
scripted response forever in any multi-call test instead of advancing (invisible in M1, where every
test only ever made one call per `LLMClient`). Fixed by caching one chat model instance per
`ModelProfile.id`, which also avoids reconstructing a real `ChatOpenAI` client on every production
call.

**Acceptance verification:** done. `tests/test_sample_briefs_ba.py` runs BA against all three
sample briefs (`appsmith/eval/sample_briefs.py` — the same three the spec names for M8's eval
harness, added now because M2 needs them): output validates, every requirement has at least one
acceptance criterion, every requirement belongs to exactly one real milestone. CLI tested at three
levels (graphs/nodes directly, the CLI's injectable wrapper functions, and `main()` with real
argv). Full suite: `uv run pytest` (42 passed), `ruff check .` (clean), `mypy appsmith` (clean, 35
source files) — re-verified against a fresh `git clone --recurse-submodules` of `asct-app`.

Full detail, including the `LLMClient` caching fix and deliberate not-yet-built pieces (`gate_ba`,
per-kind artifact export file paths): see `docs/plans/2026_11_13-m2-intake-and-ba-plan.md`.

## M3 — detail

**Done 2026-11-13.** All in `asct-be-engine`. New artifact schemas `StackChoice`, `ComponentSpec`,
`Contract`, `Architecture` (`ComponentSpec`/`Contract` are per-id artifacts, not collections —
the opposite shape from M2's `RequirementsArtifact`/`MilestonesArtifact`, matching the spec's
one-file-per-component/-contract convention). SA (`appsmith/roles/sa.py`) makes one LLM call
covering the spec's 7-step decision order; its architecture validator splits across a
self-contained Pydantic `model_validator` (dangling contract references, dependency cycles) and a
new `extra_validate` hook on `LLMClient.generate_structured` for the one check that needs data
outside the model's own response (no requirement left uncovered). Stacks are a shipped registry
(`appsmith/defaults/stacks/*.yaml`) the model picks a `stack_id` from rather than inventing.
`ComponentContextBuilder` previews the Tech Lead's view of one component (full version in M4) and
is what proves component isolation now. `appsmith run` runs `ba` then `sa`, and `--stop-after`
genuinely pauses there via LangGraph's `interrupt_before`.

Found and fixed a real bug: `run_intake_chat` and `run_project_pipeline` share
`thread_id=project_id` but, until this milestone, also shared one checkpoint file — the project
graph's new "is this a resume?" check could pick up the *intake* graph's leftover checkpoint
under that same thread id and misread it as its own prior state. Fixed with one checkpoint file
per graph name.

**Acceptance verification:** done. `tests/test_sa_node.py` exercises every validator path directly
(uncovered requirement, dangling contract reference, dependency cycle, unknown stack id — each
caught and retried). `tests/test_sample_briefs_sa.py` confirms every requirement maps to a
component on all three sample briefs. `tests/test_component_context_builder.py` confirms a
component's context never contains another component's (deliberately distinctive) spec text, in
both directions. Full suite: `uv run pytest` (59 passed), `ruff check .` (clean), `mypy appsmith`
(clean, 38 source files) — re-verified against a fresh `git clone --recurse-submodules` of
`asct-app`.

Full detail, including the checkpoint-namespace bug and deliberate not-yet-built pieces
(`gate_sa`, per-kind artifact export paths, actual contract schema authoring): see
`docs/plans/2026_11_13-m3-software-architect-plan.md`.

## M4 — detail

**Done 2026-11-14.** All in `asct-be-engine`. The big one: a real tool layer
(`appsmith/tools/`: `files.py`/`FileJail`, `commands.py`/`CommandRunner` — needed a custom
command-string tokenizer, `shlex.split(posix=True)` mangles Windows backslash paths and
`posix=False` doesn't strip quotes — `git.py`/`GitTool`, `repos.py` for per-component
repositories as submodules of the project root (or a shared root repo for `monolith_module`
components), `scaffold.py`, `gates.py`); the agent loop (`appsmith/core/agent_loop.py`,
`run_agent_loop`, deferred since M1 — uses the `json_action` protocol unconditionally, true
native tool-calling is a deferred optimization); shared DAG helpers
(`appsmith/core/dag.py`: `find_cycle` extracted from SA, plus new `transitive_closure` and
`topological_order`); the Developer role (`appsmith/roles/developer.py`); the Tech Lead role
grown to six jobs in one shared system prompt (planning, review, conflict resolution, task
re-planning, writing an end-to-end test, and summarizing the handoff); the task loop and
escalation ladder (`appsmith/graphs/component_subgraph.py::run_task` — one Python function, not
a LangGraph node per stage, since the spec's task loop is sequential); the full component build
graph (`tl_plan -> scaffold -> process_tasks -> component_e2e -> handoff`, its own checkpoint
file per component id); the `appsmith build <project> <component_id>` CLI command.

**Scope note:** the spec's "fan_out_components" (parallel multi-component builds) is M5 work per
section 10's M5 entry, not M4 — M4 builds *one* component; `appsmith build` is a separate command
from `run`'s `NODE_ORDER`, not an extension of it.

Found and fixed two real bugs along the way: `CommandRunner`'s Windows command-string splitting
(see above), and `TaskOutcome.final_profile_id` renamed to `final_role` before it ever shipped —
the task loop only ever tracked the escalation rung's role name, not a profile id.

**Acceptance verification:** done. `tests/test_component_subgraph.py` covers retry, escalation,
blocked-task (forced via `max_replans=0` for a direct test), a re-plan-then-succeed cycle, and a
manufactured merge conflict resolved by the Tech Lead. `tests/test_build_component_integration.py`
runs the *entire* pipeline for real — real git repos, a real scaffolded python-fastapi project,
real `uv run ruff`/`mypy`/`pytest` gates, FakeChatModel standing in for the model — and passed on
its first full run. `scripts/manual_m4_check.py` covers the real-model half (human-run, not CI).
Full suite: `uv run pytest` (111 passed, ~35s including two `@pytest.mark.slow` real-subprocess
integration tests), `ruff check .` (clean), `mypy appsmith` (clean, 49 source files).

Full detail, including every deliberate not-yet-built piece (task-splitting on re-plan,
`tools/http.py`, per-kind artifact export paths): see
`docs/plans/2026_11_14-m4-component-subgraph-plan.md`.

## Working agreements for future sessions

- Confirm the active milestone against this file before writing code; don't build ahead of the current
  milestone (e.g. no LangGraph graphs before M2, no tool-jail before M4) even if it looks convenient — the
  spec sequences milestones so each is independently demonstrable.
- When a milestone finishes, add a dated plan doc under `docs/plans/` (`YYYY_MM_DD-m<n>-<slug>-plan.md`)
  and update the table and "Last updated" date above before ending the session.
- If a milestone is left partially done, record exactly what's done vs. remaining under that milestone's
  row here, not just in conversation — a new session should be able to pick up from this file alone.
