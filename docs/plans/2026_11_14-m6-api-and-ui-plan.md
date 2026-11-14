# M6: API and UI — plan and record

Spec section 10, milestone 6: "Full REST and WebSocket API from section 9, then the seven
screens, with model profiles, role mapping and system prompts fully editable in Settings.
Acceptance: a Playwright smoke test drives chat, gate approval and run inspection against a
FakeLLM engine." The user also asked for a Chromium/Playwright screenshot pipeline to use as a
feedback loop while building the UI — see "The screenshot pipeline" below; it caught five of the
real bugs listed further down before any human (or test) would have otherwise noticed them.

Work spans both submodules. The full architecture reasoning (why `run_id == project_id`, why
gates are driven by `interrupt_before` recomputed per round, why execution runs on a background
thread, why `ScenarioFakeChatModel` is fully scripted rather than generic) is in the approved plan
this milestone started from; this doc records what actually got built and what went wrong along
the way.

## Engine: REST + WebSocket API (`asct-be-engine`)

New package `appsmith/api/` (previously just `main.py` with `GET /health`):

- **`run_manager.py`** — `RunManager`/`RunHandle`: starts a project-graph run on a background
  `threading.Thread`, computes `interrupt_before` from the stored gates config
  (`GATE_BEFORE_NODE = {"after_ba": "sa", "after_sa": "build_milestone"}`; `after_milestone` has no
  node to pause before yet — M7's milestone loop doesn't exist), and wraps each node callable with
  `NodeStarted`/`NodeFinished` event publishing before handing it to `build_project_graph` — the
  existing `make_ba_node`/`make_sa_node`/`make_build_milestone_node` factories are untouched.
  `approve_gate` resumes by invoking again with `interrupt_before` recomputed from the *remaining*
  enabled gates.
- **`deps.py`** — `SettingsStore`/chat-model-factory/`RunManager` as FastAPI dependencies, plus
  `resolve_project_root`/`resolve_run_root` (same lookup, matched against whichever path parameter
  name a given route uses — `{project_id}` vs `{run_id}`, see "Bugs found" below for why both
  exist).
- **`routers/projects.py`** — `POST/GET/DELETE /projects`, plus `GET /projects/{id}/files` and
  `GET /projects/{id}/file-content` (new, for the Workspace screen — not in the spec's summary
  table, which only sketches the API) with a path-traversal guard (`_resolve_within_root`).
- **`routers/chat.py`** — `WS /projects/{id}/chat`, one graph turn per message via
  `asyncio.to_thread`.
- **`routers/runs.py`** — start/status/control/events-WS, plus artifact/LLM-call/metrics
  inspection. `_all_run_ids_for` aggregates calls across the project id *and* every component id
  the Architecture lists (see bug 4 below for why that's necessary).
- **`routers/settings.py`** — models/prompts/gates/limits + a real `test-connection` check.
- **`core/metrics.py`** (new) — per-role call counts, token sums, first-attempt validation rate,
  aggregated from `CallTracer.list_calls`' raw rows (no aggregation layer existed before this).
- **`core/fake_llm.py`** gains `ScenarioFakeChatModel` — dispatches a canned response per
  requested schema name (`response_format.json_schema.name`, which `LLMClient._bind_schema`
  always sets), not a generic JSON-schema-shape generator: every canned response was hand-picked
  to agree with every other one (BA's `FR-001`, SA's `backend`/`python-fastapi`, QA's test case
  all reference the same ids), since there's no real model to read an upstream artifact and
  respond to its content. Verified end-to-end: `appsmith serve --fake-llm` drives intake through a
  full successful milestone build (`status: "ready"`) with zero bugfix rounds needed.
- **`cli.py`** gains `serve`, `export-openapi`, `export-events-schema` — the latter two write to
  `../docs/api/` (the *root* `asct-app/docs/api/`, shared with the UI repo — the engine's own
  `docs/` is not where these belong, see bug 10 below).

Small fixes to existing modules, each load-bearing for the API specifically (see "Bugs found"):
`artifacts/store.py` gains `list_all()`/`get_raw_version()`; `core/settings_store.py` gains a tiny
project registry (`list_projects`/`register_project`/`unregister_project`/`get_project_root`,
reusing the existing KV-row pattern rather than a new table); `core/db.py` switches to
`NullPool`; `core/migrate.py` gets a process-wide lock around Alembic calls.

## UI: foundation + seven screens (`asct-fe-desktop`)

Foundation: Tailwind v4 (`@tailwindcss/vite`) + a hand-built shadcn-style component set
(`src/components/ui/`: button, badge, card, input, textarea, label, separator, switch, table,
tabs, dialog, select) — the `shadcn` CLI itself currently errors ("Could not load the workspace
config") against this repo's split `tsconfig.json`/`tsconfig.app.json` layout, on both its current
release and the specific earlier version it suggested as a fallback; copying the well-known
Radix+Tailwind source directly (which is literally shadcn's own distribution model) sidesteps the
CLI bug entirely rather than fighting it. `react-router` (plain `BrowserRouter`/`Routes`, not the
data-router APIs — nothing here needs loaders) for navigation; `@xyflow/react` for the Pipeline
screen's graph. `openapi-fetch` + types generated from `docs/api/openapi.json` via
`pnpm dlx openapi-typescript@7` (not a local devDependency — see bug 9).

Screens (`src/pages/`): **Settings** (profiles with live test-connection, role mapping, prompt
editor with reset, limits, gates); **Projects** (create/open/delete, optional explicit workspace
path); **Chat** (`useChatSocket` hook, live brief panel, start-build); **Pipeline** (React Flow
graph of `ba → sa → build_milestone`, live status from `useRunEvents`'s WS feed with a
`GET /runs/{id}` fallback for a fresh page load, the gate-approval banner, per-node LLM-call
panel); **Runs and metrics** (per-role table, LLM call inspector, CSV export); **Artifacts** (list
+ version picker + raw JSON — no diff view, a deliberate cut); **Workspace** (lazy-expanding file
tree + read-only viewer against the new file-browsing endpoints — no lint/test panel or per-task
diffs, also a deliberate cut).

## The screenshot pipeline

Playwright's bundled Chromium (`pnpm exec playwright install chromium`) — no separate driver
needed. Two tools, both still in the repo for ongoing use, not just this milestone:

- `scripts/screenshot.mjs` — navigate-and-screenshot against a running `pnpm dev`, for the
  day-to-day loop: make a change, screenshot, read the PNG back, fix what's wrong.
- `scripts/interact-and-shot.mjs` — the same, but clicks through one or more selectors first (open
  a dialog, expand a tree node) before capturing.

`playwright.config.ts` + `e2e/smoke.spec.ts` is the separate, formal acceptance test — it starts
its own isolated `appsmith serve --fake-llm` and `vite` instances (ports 8010/5175, an isolated
`--db-path` under `test-results/`) and drives the literal acceptance scenario through the real UI:
create a project, chat it to a frozen brief, start a run, wait for the real `after_sa` gate,
approve it, then confirm the Runs and Artifacts screens show real data.

Used throughout screen-building, not just at the end — it directly caught bugs 5, 6, 7 and 9
below before they shipped, by looking at what the running app actually rendered rather than
trusting that the code read correctly.

## Bugs found (ten, across both repos)

1. **FastAPI `Depends` functions typed `request: Request` fail on WebSocket routes** with
   `missing 1 required positional argument: 'request'` — a WS connection has no `Request` object.
   Fixed by typing every shared dependency as `starlette.requests.HTTPConnection` (the common base
   `Request`/`WebSocket` both subclass) instead.
2. **`DELETE /projects/{id}`'s `shutil.rmtree` silently failed on Windows** (`ignore_errors=True`
   masked it) because `ArtifactStore`/`CallTracer`/`SettingsStore` each open a fresh SQLAlchemy
   engine per call with no explicit disposal, and SQLAlchemy's default connection pool keeps a
   DBAPI connection open until something calls `.dispose()` — on Windows, an idle pooled sqlite3
   connection keeps the file locked. Fixed by switching `core/db.py`'s `make_engine` to
   `NullPool` (SQLite gains nothing from pooling anyway; each "connection" is a cheap local file
   handle).
3. **Alembic's `env.py`-loading machinery isn't thread-safe** — two `command.upgrade(...)` calls
   from different threads can stomp on each other's module-global state
   (`KeyError: 'config'`, spurious `ResolutionError: No such revision`). Nothing before M6 ever
   called a migration from more than one thread (every entry point was synchronous/CLI-only); the
   API's background-thread run execution is what first made this reachable. Fixed with a
   process-wide `threading.Lock` around both `migrate_settings_db`/`migrate_project_db`.
4. **Component-level LLM calls (`tl_plan`, `dev_implement`, `tl_review`, `handoff`) never showed
   up in "run inspection"** — they trace under the *component* id as `run_id` (an M4 convention,
   predating this API), not the project id. `GET /runs/{id}/llm-calls`/`/metrics` now aggregate
   across the project id and every component id the Architecture lists
   (`_all_run_ids_for` in `routers/runs.py`).
5. **`ScenarioFakeChatModel`'s intake-turn counter never advanced** — `_compile_intake` originally
   built a fresh `LLMClient` (and therefore a fresh model instance) on every WS message, so a
   stateful fake could never see more than one call. Fixed by constructing one `LLMClient` for the
   whole WS connection's lifetime, matching the existing "one chat model per profile id" caching
   contract `LLMClient` already documents.
6. **The chat WS never sent a close frame after `ready_to_build`** — the handler just returned
   when its loop condition went false, which tears down the raw connection with no WS close
   handshake. FastAPI's in-process `TestClient` tolerated this silently (how the whole backend
   test suite missed it); a real `websockets` client against a live `uvicorn` server raised
   `ConnectionClosedError`/`EOFError`. Fixed with an explicit `await websocket.close()`.
7. **The sidebar's project-scoped nav (Chat/Pipeline/Artifacts/...) never appeared** — it called
   `useParams()`, which only sees params from routes it's rendered *inside*; the sidebar is a
   sibling of `<Routes>`, not nested under a matched route. Fixed with `useMatch` instead, which
   matches the current location directly regardless of where it's called from.
8. **Pipeline nodes always showed "idle" even after BA/SA had genuinely finished** (confirmed by
   the gate having been reached) — `result.ba ||= 'success'` never fires once `result.ba` is
   already the *truthy* string `'idle'`; `||=` only assigns on falsy values. Fixed by keeping
   unresolved nodes as `undefined` (so `??=`, which only assigns on null/undefined, actually
   works) and only defaulting to `'idle'` as the very last step.
9. **The Workspace file tree was cluttered with `.venv`, `__pycache__`, `.ruff_cache`,
   `.mypy_cache`, `.pytest_cache`** — real toolchain artifacts from the gates that ran during the
   build, not anything a human browsing "what got built" wants to see. Added to the engine's
   `_HIDDEN_ENTRIES` set alongside `.git`/`.appsmith`.
10. **Two dev-tooling-only path/location mismatches**, unrelated to application code:
    Vite's dev server binds to the IPv6 loopback under the `localhost` hostname by default on this
    machine, not the IPv4 literal — `curl http://127.0.0.1:5173` connection-refuses even though
    the server is genuinely listening; `scripts/screenshot.mjs` and the Playwright config use
    `localhost` instead. And the engine's own `docs/` is not the OpenAPI export target — the root
    `asct-app/docs/api/` is (shared with the UI repo) — `export-openapi`'s default `--out` is now
    `../docs/api/openapi.json`, relative to where `appsmith` is actually run from.

## Scope decisions (deliberate, not oversights)

- `run_id == project_id`; `approve_gate` is the only implemented `/runs/{id}/control` action
  (`pause`/`resume`/`retry_node`/`restart_from_node` return a clear "not implemented" response);
  `ArtifactWritten`/`MetricsUpdated`/tool-call events are not published over the WS feed. All
  carried over unchanged from the approved plan — see that document for the full reasoning.
- Artifacts screen has no diff view; Workspace screen has no lint/test-result panel or per-task
  diffs. Both are real, working, read-only views of real data — just not the richest version the
  spec's screen descriptions gesture at.
- The acceptance Playwright test doesn't assert the full milestone build *succeeds* — only that
  the run moves genuinely past the gate and that Runs/Artifacts show real data regardless of
  outcome. In practice, against `ScenarioFakeChatModel`'s current scripted scenario, it reliably
  does succeed (verified manually, repeatedly, via the screenshot pipeline) — but asserting on
  that specific outcome would make the test fragile to a scenario change for no acceptance-related
  reason.

## Acceptance verification

`asct-fe-desktop`'s `e2e/smoke.spec.ts` (`pnpm run e2e`) is the literal acceptance scenario,
passing against a real, from-scratch `appsmith serve --fake-llm` + `vite` pair the config starts
itself: project creation → chat to a frozen brief → run start → real `after_sa` gate reached →
approved via the UI → Runs screen shows real `ba`/`sa` calls → Artifacts screen shows the real
`Architecture` artifact's content, including the project's own id.

Backend: `uv run pytest` (175 passed, ruff clean, `mypy --strict` clean on 63 source files) —
re-verified against a fresh `git clone --recurse-submodules` of `asct-app`. Frontend: `pnpm build`
(`tsc -b && vite build`) and `pnpm lint` (oxlint) both clean.

## Deliberately not built (carried forward, not forgotten)

- The Tauri desktop shell (`src-tauri/`) — still M8, as planned; the UI runs as a local web app
  against the engine sidecar until then, exactly as this milestone's work assumes.
- `appsmith eval` and the Model Manager screen — M8.
- M7's milestone loop (`after_milestone` gate, "run milestones in order", change requests) —
  `build_milestone` still builds every component the Architecture lists in one pass.
- Code-splitting the UI bundle (`vite build` warns at 627 kB) — not a correctness issue, deferred.
