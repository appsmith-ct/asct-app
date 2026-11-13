# M5: Integration, staging and QA — plan and record

Spec section 10, milestone 5: "Parallel component fan-out, integration checks against contracts,
staging deploy (compose or supervisor), QA agent writing black-box tests from requirements, bug
triage back to Tech Leads, bounded fix rounds, container execution option. Acceptance: a
two-component sample (backend plus frontend) reaches 'ready' or a clear failure report."

All work in `asct-be-engine`.

## What got built

**`appsmith/graphs/milestone_flow.py`** (new) — the milestone-level cycle the spec's mermaid
diagram draws as `COMP -> INT -> QA -> BUGS -> (COMP again, bounded) -> DEMO`:

- `fan_out_components` — builds every component the Architecture lists, one after another, by
  calling a new extracted `run_component_build` (factored out of `appsmith.cli.build_component`,
  which M4 shipped as its own command; M5 reuses the same per-component graph-compile-and-invoke
  logic without duplicating it).
- `integrate_stage` — every component must be `done`, and every contract's producer and every
  consumer must be `done`, before staging is worth attempting. Saves an `IntegrationReport`.
- `stage_components` — starts every component as a local process (`appsmith/tools/deploy.py`'s
  `Supervisor`) and polls its health endpoint. Saves a `StagingReport`.
- `run_qa_cycle` — generates a `TestPlan` from Requirements alone (`appsmith/roles/qa.py`,
  written earlier in this session), then executes it for real against the staged URLs. Saves the
  `TestPlan` and the resulting `QAReport`.
- `triage_and_fix_bugs` — assigns each `BugReport` to its `suspected_component` (QA always sets
  this, since it writes each test against one named component — the spec's "otherwise the SA
  decides" fallback never triggers here) and re-enters that component's task loop (`run_task`,
  from `component_subgraph.py`) with the bug as a `Task`. The bugfix task's `files` come from the
  component's own `ComponentPlan.code_structure` — QA is black-box and can't name a file, so there
  is no extra LLM call to decide one.
- `build_and_verify_milestone` — the orchestrating function: fan out, integrate, then loop
  stage-QA-triage up to `bugfix_rounds` times, and write the final `MilestoneReport`
  (`status: "ready" | "failed"`, `unresolved_bugs`, `bugfix_rounds_used`, a human summary).

Like `run_task`/`process_tasks` in M4, this whole cycle is **one plain Python function**, not a
web of LangGraph conditional edges: the loop is bounded and sequential, so a function expresses
the real control flow directly while staying just as testable. It's wired into the project graph
as a single new node, `build_milestone` (`appsmith/graphs/project_graph.py`), appended after `sa`:
`NODE_ORDER` is now `["ba", "sa", "build_milestone"]`, and `appsmith run`'s `--stop-after` default
moved from `sa` to `build_milestone` (the parser's own default tracks `NODE_ORDER[-1]`; the
`run_project_pipeline` function's own default parameter stays `"sa"`, so no existing test calling
it directly needed to change).

**New schemas** (`appsmith/artifacts/schemas.py`): `ComponentHealth`, `StagingReport`,
`IntegrationReport`, `TestCase`, `TestPlan`, `BugReport`, `QAReport`, `MilestoneReport`. Everything
is keyed by `project_id` except `TestCase`/`BugReport`, which are plain records inside their
parent artifact — same "collection vs. one-file-per-id" split the spec table already draws for
`Requirement`/`Milestone` vs. `ComponentSpec`/`Contract`.

**`appsmith/roles/qa.py`** (new) — `QAContextBuilder` (Requirements only, matching the spec's
"who sees what" row for QA); `run_test_plan_generation` (one schema-constrained call producing
`TestCase`s, `extra_validate`-checked against real requirement/component ids); `execute_test_plan`
(the ground-truth half — runs every `TestCase` for real via `StagingHttpClient` and turns a
mismatch into a `BugReport`, with `suspected_component` already filled in).

**`appsmith/tools/http.py`** (new) — `StagingHttpClient`: `httpx`-based, allowlisted to the
staging URLs the deploy recipe actually produced (spec section 8: "`http_request` ... Only to
staging URLs the deploy recipe declares").

**`appsmith/tools/deploy.py`** (new) — `Supervisor`: starts/polls/stops local subprocesses. No
Docker-compose path (see Scope decisions).

**`appsmith/tools/container.py`** (new) + `CommandRunner.use_container`/`container_image` — the
"container execution option" the spec calls out as its own M5 deliverable (section 8, safety
caveat). `docker_available()` + `wrap_in_container()` wrap a command's argv in `docker run --rm`.
Each `StackProfile`/`StackChoice` now carries a `container_image` (python-fastapi:
`ghcr.io/astral-sh/uv:python3.12-bookworm-slim`, which ships `uv` preinstalled; typescript-react:
`node:20-slim`). `Limits.container_execution` is the per-project toggle; see Scope decisions for
why it defaults to **off** despite the spec's "recommended as the default."

## Scope decisions (deliberate, not oversights)

- **Sequential fan-out, not LangGraph `Send`.** `Limits.max_concurrent_llm_calls` defaults to 1,
  which makes genuine parallel component builds moot for now — a sequential Python loop expresses
  the same outcome without a parallel-fan-out mechanism that has nothing to actually parallelize.
- **Supervisor-only staging, no Docker-compose path.** Simpler, deterministic, and testable without
  needing Docker as a hard dependency for every run.
- **Milestone-scoping is M7, not M5.** `fan_out_components`/`build_milestone` build every component
  the Architecture lists, not just one milestone's worth — spec milestone 7 is explicitly "run
  milestones in order", which doesn't exist yet. `ProjectState`/`build_milestone` will need real
  per-milestone component filtering once M7 exists.
- **The acceptance test's "frontend" is a second python-fastapi component, not a real
  `typescript-react` one.** `scaffold_typescript_react` (M3) is a minimal stub with no working dev
  server script — there's no real frontend toolchain to stage yet. The acceptance test tags its
  second component `kind="frontend"` to satisfy the "backend plus frontend" framing at the role
  level, while both use the stack that's actually stageable today. Revisit once the frontend stack
  gets a real dev-server scaffold.
- **Bugfix `Task.files` comes from `ComponentPlan.code_structure`**, not a fresh LLM call deciding
  which files a bug touches — QA is black-box and genuinely doesn't know, and the Tech Lead's own
  plan already names every file it expects to exist.
- **`container_execution` defaults to `False`**, not the spec's suggested default-on. The feature
  is fully implemented and works (`tests/test_container.py`'s `@pytest.mark.slow` test actually
  runs a command inside a real Docker container) — but turning it on by default actively broke
  real builds on this Windows dev machine: Docker Desktop's bind mount marks every file executable
  inside the Linux container regardless of its Windows permissions, which trips ruff's `EXE002`
  ("executable file but no shebang") on every single scaffolded file before a Dev even runs. This
  is a host/Docker interaction, not something the container side can fix. Recommended to enable
  explicitly (`appsmith config set-limits --container-execution`) on hosts where that doesn't bite.

## Bugs found and fixed along the way

Three of these were **pre-existing** (M3/M4 code, not touched until M5 exercised the real-gate
path against two components instead of one) and would have surfaced in M4 too under the right
conditions; one is new to M5.

1. **Scaffold's own `tests/test_health.py` failed `ruff check .`'s import-sort rule**, and in a
   way that depends on *where the scaffolded project sits on disk* — nested inside another
   project with its own `pyproject.toml`/`.git` (e.g. under this very repo) resolves ruff's
   first-party auto-detection one way; standing alone (e.g. under a pytest temp dir) resolves it
   the other way. Fixed by making it not depend on auto-detection at all: the scaffolded
   `pyproject.toml` now declares `[tool.ruff.lint.isort] known-first-party = ["<module>"]`
   explicitly (`appsmith/tools/scaffold.py`). This was latent since M4 — `test_health.py` was
   never actually gate-checked by the M4 acceptance test, which only exercises a *new* file
   (`domain/order.py`), not the scaffold's own starter file.
2. **`uv run uvicorn ... --reload` leaks a zombie subprocess on Windows.** `--reload` spawns a
   file-watcher parent plus a separate worker process; `subprocess.Popen.terminate()` only reaches
   the parent, leaving the worker (and, on Windows, a venv launcher shim that's itself a *child*
   process rather than an in-place exec) running and holding the port and the venv's files open.
   33 such zombies had already accumulated across this session's earlier slow tests by the time
   this was caught. Fixed two ways: removed `--reload` from the python-fastapi stack's
   `run_command` (staging never needed live-reload — that's a dev-server convenience, not a
   deployed process's concern; `run_command` has no other caller, confirmed via grep), and made
   `Supervisor` kill the whole process tree instead of just the direct child (`taskkill /F /T` on
   Windows, a process-group signal via `start_new_session`/`os.killpg` on POSIX) as defense in
   depth against the venv-shim case specifically.
3. **The Tech Lead's E2E test content (`import backend.main` with no further use) trips ruff's
   `F401`** once something actually lints it — which M4's own component build never does (its
   `component_e2e` node writes and commits the E2e file but runs no gate on it), but M5's bugfix
   round does, since a bugfix task's gate re-lints the *whole* component directory, including
   files committed by earlier steps. Fixed in the M5 test fixtures by writing E2E content that
   uses its import (`assert app is not None`) instead of a bare unused import — not a product bug,
   since the Tech Lead's own prompt doesn't ask for unused imports; this was purely a test-fixture
   artifact exposed by exercising a lint path M4 never reached.
4. **`stage_components` stopped every staged server before QA ever got to test them** (new to
   M5). The original version opened its own `with Supervisor() as supervisor:` block, started and
   health-checked every component, and returned — which calls `Supervisor.__exit__`/`stop_all()`
   *before* `run_qa_cycle` runs its HTTP checks in a later, separate function call. Every QA check
   against a "healthy" `StagingReport` came back connection-refused. Fixed by making
   `build_and_verify_milestone` own one `Supervisor` per round (via a new `_stage_and_run_qa`
   helper) spanning both the staging call and the QA cycle call, so the servers stay up until
   that round's QA is actually done.

## Acceptance verification

`tests/test_milestone_flow.py::test_build_and_verify_milestone_reaches_ready_after_one_bugfix_round`
(`@pytest.mark.slow`) is the literal acceptance scenario: two real components (`backend`,
`frontend`, both python-fastapi per the scope note above) are built end to end with FakeChatModel
standing in for the model, staged as real local processes, and QA'd for real over HTTP. Round 1's
scripted QA plan has a deliberately wrong expectation for `backend` so a real `BugReport` gets
raised and a real bugfix round runs (a no-op fix, since the server was never actually broken, per
the `ComponentPlan.code_structure` scope note) before round 2's corrected plan passes. Final
`MilestoneReport`: `status="ready"`, `bugfix_rounds_used=1`, `unresolved_bugs=[]`.

Fast (non-slow) unit tests cover `integrate_stage`'s ready/not-ready logic and idempotency, and
`run_qa_cycle`'s bug-reporting and artifact-versioning/idempotency against a stub `StagingReport`
(no real server needed for that one). `tests/test_container.py` covers the container-execution
option: a deterministic argv-wrapping test, a `CommandRunner` wiring test, and a `@pytest.mark.slow`
test that actually runs a command inside a real Docker container (Docker is installed and
reachable on this dev machine, confirmed via `docker version`/`docker pull`).

Full suite: `uv run pytest` (128 passed, ~94s including every `@pytest.mark.slow` real-subprocess
test), `ruff check .` (clean), `mypy appsmith` (clean, 54 source files) — re-verified against a
fresh `git clone --recurse-submodules` of `asct-app` (see the PROGRESS.md entry for the exact
command and result).

## Deliberately not built (carried forward, not forgotten)

- Docker-compose staging (supervisor-only, see Scope decisions).
- Real parallel component fan-out via LangGraph `Send` (sequential for now, see Scope decisions).
- A real `typescript-react` dev-server scaffold (M3's stub has no working `pnpm dev`; staging a
  real frontend needs this first).
- Milestone-scoped builds (`build_milestone` builds everything the Architecture lists; M7 is where
  "run milestones in order" actually gets implemented).
- `Supervisor`'s process-tree kill is POSIX/Windows-only logic with no test on POSIX (this dev
  machine is Windows) — the `start_new_session`/`killpg` branch is written to the same contract as
  the Windows `taskkill` branch but only exercised by code review, not a passing test, since there's
  no POSIX CI runner available in this session.
