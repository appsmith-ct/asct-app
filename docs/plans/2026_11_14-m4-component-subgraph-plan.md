# M4: Component subgraph — Plan

Date: 2026-11-14
Status: **Done**

## Goal (from the spec, section 10)

> Tool layer (jailed files, command allowlist, git), creation of one repository per component plus
> the project root repository with submodules (a single repository for a monolith), TL planning
> (internal design, tasks), Dev loop with escalation ladder, gates, TL review, merge, component
> end-to-end tests.
>
> Acceptance: one backend component of a sample brief is built unattended with a real model; with
> FakeLLM, tests cover retry, escalation, blocked-task and merge-conflict paths.

## Scope note decided early

The spec's "fan_out_components" — building every component of a project in parallel — is listed
under the *project* graph, and section 10's M5 entry explicitly says "Parallel component
fan-out...". So M4 delivers the capability to build **one** component end to end; running it
across every component of a project is M5's job. This showed up as a new, separate CLI command,
`appsmith build <project> <component_id>`, rather than an extension of `appsmith run`'s
`NODE_ORDER` mechanism.

## What was done (all in `asct-be-engine`)

1. **Tool layer** (`appsmith/tools/`). `files.py` (`FileJail`: read/list/search/write/apply_edit,
   every path resolved against a jail root and rejected if it escapes). `commands.py`
   (`CommandRunner`: allowlisted by prefix, `shell=False`, timeout, truncated output, a scrubbed
   environment — needed a custom tokenizer, `_split_command`, because `shlex.split(posix=True)`
   mangles Windows backslash paths and `posix=False` doesn't strip quote characters; the fix splits
   with `posix=False` then strips one layer of matching quotes per token). `git.py` (`GitTool`:
   init/status/diff/add/commit/branch/checkout/`submodule_add`/`merge_squash`, with conflict
   detection — verified empirically that resolving a squash-merge conflict and committing needs no
   `merge --continue`). `repos.py` (`ensure_project_root_repo`/`ensure_component_repo`: one
   repository per component as a submodule of the project root, except a `monolith_module`
   component, which lives directly in the root repo as a subdirectory — verified empirically that
   `git submodule add` recognizes an already-initialized directory and registers it in place
   instead of re-cloning). `scaffold.py` (stack-keyed starter-file templates, a caller-supplied
   confirm command — verified a real `uv run pytest` against the scaffolded python-fastapi project
   actually passes). `gates.py` (`run_gates`: the stack's lint/typecheck/test commands, run for
   real, never judged by an LLM — spec section 7.7).

2. **The agent loop** (`appsmith/core/agent_loop.py`), `run_agent_loop`, deferred since M1. Uses
   the `json_action` protocol (one schema-constrained `{tool_call}` or `{done}` action per turn,
   built directly on `LLMClient.generate_structured`) regardless of a profile's configured `tools`
   strategy — native tool-calling wiring is a deliberately deferred optimization. Handles: unknown
   tool rejection (retried via `extra_validate`), tool-handler exceptions fed back to the model as
   text rather than raised, repeated identical actions aborting the loop, step-budget exhaustion.

3. **Shared DAG helpers extracted** (`appsmith/core/dag.py`): `find_cycle` (pulled out of SA's M3
   inline cycle detector), `transitive_closure` and `topological_order` (new, for the Tech Lead's
   task graph and the task-processing order).

4. **New artifact schemas**: `Task`, `FileResponsibility`, `ComponentPlan`, `TaskOutcome`,
   `ComponentReport`. `ComponentSpec` gained a `stack_id` field — the resolved `StackChoice`
   (language/framework/etc.) alone isn't enough to know which shipped scaffold template to use;
   the SA now records which registry id it picked, not just what it resolved to.

5. **Tech Lead role** (`appsmith/roles/tech_lead.py`) grew from M3's planning-only role to six
   jobs, each a prompt section in one shared `system.md.j2` (this codebase's established pattern —
   one system prompt per role, not per step): planning (`tl_plan`, unchanged from M3), reviewing
   (`run_tl_review` — approve/changes with concrete items, spec 7.8), resolving a merge conflict
   (`run_conflict_resolution`), re-planning a stuck task (`run_task_replan` — rewrites description
   and acceptance only; splitting a task into several is a larger change deferred past this
   milestone), writing an end-to-end test (`run_component_e2e` — the same jailed-tools agent loop
   machinery a Dev uses, reused rather than duplicated), and summarizing the handoff
   (`run_handoff_summary` — the model only writes the free-text parts; `task_outcomes`,
   `blocked_task_ids` and `status` are filled in deterministically from data the orchestration
   already has). `TechLeadContextBuilder` is the real version of the M3 "preview"
   (`ComponentContextBuilder`, now deleted): own `ComponentSpec`, own `Contract`s, and — new here —
   only the `Requirement`s the spec actually claims, found via `ComponentSpec.parent_ids[0]`
   (finally giving `parent_ids` a real use).

6. **Developer role** (`appsmith/roles/developer.py`): `DevContextBuilder` (Task + ComponentSpec +
   relevant Contracts only), `make_dev_tools` (wraps `FileJail`/`CommandRunner`/`GitTool` as
   `ToolSpec`s — `write_file`/`apply_edit` reject any path outside the task's own `files` list
   before ever reaching `FileJail`, a second jail layer on top of the component-directory one),
   `run_dev_implement`.

7. **The task loop and escalation ladder** (`appsmith/graphs/component_subgraph.py::run_task`).
   One Python function (not a LangGraph node per stage — the spec's task loop is sequential, "in
   dependency order", not concurrent, so a plain function captures the real control flow while
   staying tractable): `dev_implement` -> `run_gates` (deterministic) -> `tl_review`, retrying at
   the same rung up to `dev_attempts` times, escalating through `dev_intern` -> `dev_mid` ->
   `dev_senior` -> the Tech Lead's own profile, re-planning after every rung is exhausted, and
   marking the task `blocked` after `max_replans` re-plans still fail. `merge_task_branch` squash-
   merges an approved task's branch, resolving conflicts via the Tech Lead when they occur.
   `run_gates_fn` has no default — a silently-always-passing default would be exactly the
   "approval without a green gate" the spec says the engine must reject.

8. **The full component build graph** (`build_component_graph`): `tl_plan` -> `scaffold` ->
   `process_tasks` (calls `run_task` once per task, in topological order) -> `component_e2e` ->
   `handoff` (writes the `ComponentReport`). Checkpointed under its own file, keyed by component id
   within the thread (`project_checkpoint_db_path(project_root, f"component-{component_id}")`),
   consistent with the M3 lesson about not sharing a checkpoint file across different graphs.

9. **CLI**: `appsmith build <project> <component_id>`.

10. **Manual real-model script** (`scripts/manual_m4_check.py`): takes a sample brief, skips the
    intake chat, runs BA then SA, then builds the first `backend_service` component — unattended,
    against a real OpenAI-compatible server.

## Acceptance check

- [x] **With FakeLLM, tests cover retry, escalation, blocked-task and merge-conflict paths** —
      `tests/test_component_subgraph.py`: retry within a rung, escalation to the next rung after
      exhausting attempts, blocked after exhausting every rung (`max_replans=0` for a direct,
      minimal test), a re-plan cycle that then succeeds, and a merge conflict manufactured
      directly (two divergent branches) and resolved by `merge_task_branch`'s Tech-Lead-assisted
      step. All five passed on the first full run after fixing the FakeChatModel response-queue
      scripting for the mixed-profile scenarios (see "Notes" below).
- [x] **One backend component of a sample brief is built unattended with a real model** — the
      human-run half is `scripts/manual_m4_check.py`. The FakeLLM equivalent,
      `tests/test_build_component_integration.py`, runs the *entire* pipeline for real (real git
      repos, a real scaffolded python-fastapi project, real `uv run ruff`/`mypy`/`pytest` gates,
      FakeChatModel standing in for the model) and passed on its first full run — a strong signal
      the wiring across M4's many pieces is actually correct together, not just piece by piece.
- [x] Full suite: `uv run pytest` (111 passed, ~35s — the two real-subprocess integration tests
      are marked `@pytest.mark.slow` but still run by default), `ruff check .` (clean), `mypy
      appsmith` (clean, 49 source files).

## Notes / deviations

- `run_task_replan` only rewrites a task's `description`/`acceptance` — the spec also allows
  "split it"; splitting would ripple into the plan's dependency graph and file-ownership
  validation in ways this milestone didn't take on.
- `component_e2e` tests in-process (e.g. the stack's own test client) rather than starting a real
  server process, to avoid port/lifecycle management — not spelled out by the spec either way.
- Per-kind artifact export file paths matching the spec's exact names (`docs/components/<id>/plan.json`,
  etc.) are still not wired up — same generic `docs/artifacts/<kind>/<id>/v<N>.json` convention
  from M1-M3.
- `appsmith/tools/http.py` (QA/SA's staging-URL-only HTTP tool) is still an empty placeholder —
  nothing in M4 needed it; it arrives with QA in M5.
- A genuinely organic merge conflict (sequential single-branch-per-task execution with the plan
  validator enforcing disjoint files for parallel tasks) doesn't naturally arise in M4's scope —
  the merge-conflict test manufactures one directly and tests `merge_task_branch` as a unit,
  which tests the real mechanism without depending on a scenario that may not occur until
  multiple Dev Teams work the same component concurrently (noted as a future capability in the
  spec itself).
- Found two real bugs while building and testing this milestone, both fixed (not just a model-
  response-order scripting mistake, see below, which doesn't need a code fix): `CommandRunner`'s
  command-string splitting on Windows (see the `_split_command` entry above), and
  `TaskOutcome.final_profile_id` renamed to `final_role` before it ever shipped — the task loop
  only ever tracked the escalation rung's *role name* (`dev_intern`, etc.), not a profile id, so
  the field name was wrong from the start.
- Several of this milestone's FakeLLM tests needed care around `LLMClient`'s per-profile-id
  response cache (added in M2): `tl_review`/`merge`/`e2e`/`handoff` and `dev_implement` draw from
  different profiles' queues unless the test deliberately shares one id, and the top escalation
  rung (`tech_lead`) shares its profile with the Tech Lead's own planning/review/e2e/handoff calls
  in production — worth remembering when scripting a test that reaches the top rung.
