# Appsmith-CT — Build Progress

This is a living status tracker, updated as work happens, so progress survives context compaction across
Claude Code sessions. For what each milestone requires, see
`docs/specs/2026_11_13-appsmith_ct_implementation_specification.md`, section 10. For how a specific
milestone was executed, see the matching dated plan in `docs/plans/`.

Last updated: 2026-11-13

## Milestone status

| Milestone | Status | Plan doc |
| --- | --- | --- |
| M0: Skeleton | **Done** | `docs/plans/2026_11_13-m0-skeleton-plan.md` |
| M1: Engine foundation | **Done** | `docs/plans/2026_11_13-m1-engine-foundation-plan.md` |
| M2: Intake and BA | **Done** | `docs/plans/2026_11_13-m2-intake-and-ba-plan.md` |
| M3: Software Architect | Not started | — |
| M4: Component subgraph | Not started | — |
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
source files).

Full detail, including the `LLMClient` caching fix and deliberate not-yet-built pieces (`gate_ba`,
per-kind artifact export file paths): see `docs/plans/2026_11_13-m2-intake-and-ba-plan.md`.

## Working agreements for future sessions

- Confirm the active milestone against this file before writing code; don't build ahead of the current
  milestone (e.g. no LangGraph graphs before M2, no tool-jail before M4) even if it looks convenient — the
  spec sequences milestones so each is independently demonstrable.
- When a milestone finishes, add a dated plan doc under `docs/plans/` (`YYYY_MM_DD-m<n>-<slug>-plan.md`)
  and update the table and "Last updated" date above before ending the session.
- If a milestone is left partially done, record exactly what's done vs. remaining under that milestone's
  row here, not just in conversation — a new session should be able to pick up from this file alone.
