# M1: Engine foundation — Plan

Date: 2026-11-13
Status: **Done**

## Goal (from the spec, section 10)

> Config loader (`roles.yaml`, ModelProfile), LLMClient with constrained JSON output, validation and
> retry, FakeLLM provider, SQLite models and migrations, settings tables for model profiles, role
> mapping and system prompts seeded from the shipped defaults, an `appsmith config` command to read and
> write them until the UI exists, event bus, `llm_calls` tracing, artifact store with versions and file
> export, ContextBuilder base class.
>
> Acceptance: a test runs a two-node LangGraph with FakeLLM, writes a versioned artifact, resumes after
> a simulated crash, and records every call; a manual script does the same against a real local
> endpoint.

## What was done (all in `asct-be-engine`)

1. **Config loader** (`appsmith/core/model_profile.py`, `appsmith/core/config.py`). Pydantic models
   `ModelProfile`, `RoleConfig`, `Limits`, `RolesConfig` mirror the `roles.yaml` shape from spec
   section 4. `load_default_roles_config()` reads the shipped `appsmith/defaults/roles.yaml` via
   `importlib.resources`. A profile's `id` is populated from its dict key by `RolesConfig.model_post_init`,
   and role→profile references are validated at parse time.

2. **Two SQLite databases, two Alembic environments** (`appsmith/core/db.py`, `appsmith/core/paths.py`,
   `appsmith/core/migrate.py`, `migrations/settings_db/`, `migrations/project_db/`,
   `alembic.settings.ini`, `alembic.project.ini`). Settled on a two-database split consistent with
   sections 4, 8 and 9 of the spec:
   - **App (settings) database** — one per user, under the platformdirs app-data directory. Holds
     `model_profiles`, `role_mappings`, `system_prompts` (full version history — a reset writes a new
     version containing the default text, rather than deleting history, so an old `llm_calls` row's
     `prompt_version` always resolves), and `kv_settings` (limits, gates; a small JSON table rather than
     two near-empty dedicated tables).
   - **Project database** — one per project, under `<project>/.appsmith/project.sqlite3`. Holds
     `artifacts` and `llm_calls`. LangGraph's own `SqliteSaver` checkpointer uses a third, separate file
     (`checkpoints.sqlite3`) that this engine code never touches directly.
   - Each database has its own hand-written initial Alembic revision (autogenerate wasn't worth it for
     schema this small and fixed); `appsmith/core/migrate.py` runs either one programmatically against a
     given SQLite path (`command.upgrade(cfg, "head")` with `sqlalchemy.url` overridden in-memory), so
     nothing shells out to the `alembic` CLI at runtime. `ArtifactStore`, `CallTracer` and
     `SettingsStore` all call the relevant migration in `__init__`, so a fresh database is always
     brought to `head` on first use.

3. **Artifact store** (`appsmith/artifacts/schemas.py`, `appsmith/artifacts/orm.py`,
   `appsmith/artifacts/store.py`). `Artifact` is the generic envelope from spec section 6 (id, version,
   produced_by, created_at, parent_ids); concrete artifact kinds (`Requirement`, `ComponentSpec`, ...)
   will subclass it starting in M2. `ArtifactStore.save()` is idempotent: saving the same
   (kind, id, version) twice with identical content is a no-op, but different content raises
   `ArtifactConflictError` — artifacts are immutable once written. Every save also exports a readable
   JSON file to `<project>/docs/artifacts/<kind>/<id>/v<N>.json` plus a `latest.json`. Per-kind export
   paths matching the spec's table in section 6 (`docs/brief.json`, `components/<id>/spec.json`, ...)
   arrive with each concrete artifact kind in M2+; M1 only had the generic envelope to work with.

4. **LLMClient and FakeChatModel** (`appsmith/core/llm_client.py`, `appsmith/core/fake_llm.py`).
   `LLMClient.generate_structured(schema=..., messages=..., profile=..., ...)` binds a JSON-schema
   `response_format` hint (ignored by chat models that don't understand it, honoured by a real
   OpenAI-compatible constrained-decoding endpoint), validates the response with Pydantic, and on
   failure retries with the validation error appended to the conversation (default 3 attempts).
   Persistent failure raises `StepFailed`. Every attempt is traced via `CallTracer`, successful or not.
   `FakeChatModel` (a real `BaseChatModel` subclass, not a mock) returns a scripted list of responses in
   order and raises `FakeChatModelExhausted` if called more times than scripted — this is what the
   crash-resume test uses to prove the LLM wasn't called twice. `run_agent_loop` (the tool-using agent
   loop from spec section 7.1) is **not** implemented yet — it has no caller until the tool layer exists
   in M4, and an unused method would just be dead code.

5. **Tracing** (`appsmith/core/tracing_orm.py`, `appsmith/core/tracing.py`). `CallTracer` records every
   `generate_structured` attempt (run, node, role, profile, prompt version, full prompt, full response,
   approximate input/output token counts, latency, validation outcome, retry index) to the project
   database's `llm_calls` table, per spec section 7.10.

6. **Event bus** (`appsmith/core/events.py`). A synchronous in-process pub/sub `EventBus` plus the
   typed event vocabulary from spec section 9 (`NodeStarted`, `NodeFinished`, `LLMCallRecorded`,
   `ArtifactWritten`, `GateReached`, `MetricsUpdated`) as Pydantic models. `LLMClient` publishes
   `LLMCallRecorded` when given a bus. The WebSocket-facing async version that actually streams these to
   the UI arrives with the API in M6; for now this is internal plumbing other engine code (and tests)
   can subscribe to directly.

7. **ContextBuilder base class** (`appsmith/context/base.py`, `appsmith/core/tokencount.py`). Abstract
   base: subclasses implement `gather_items()`; the base `build()` filters by the role's artifact-kind
   whitelist (logging and returning what was excluded — this is the mechanism a future per-role unit
   test can assert against to prove no cross-role leakage), then fits what's left into the role's token
   budget by dropping the lowest-priority items first, logging what was dropped. If even the single
   highest-priority item doesn't fit, it raises `TokenBudgetExceeded` rather than silently truncating.
   Token counts are an approximate chars-per-token heuristic (`appsmith/core/tokencount.py`) — exact
   OpenAI-style tokenization wouldn't match a Bonsai/Qwen model anyway, so it isn't worth a tokenizer
   dependency yet. Concrete per-role subclasses arrive with each role (M2+).

8. **Settings store and seeding** (`appsmith/core/settings_orm.py`, `appsmith/core/settings_store.py`).
   `SettingsStore.seed_defaults_if_empty()` copies the shipped `roles.yaml` and the per-role placeholder
   prompts (`appsmith/defaults/prompts/<role>/system.md.j2` — generic placeholder text for now; each
   role's real prompt, with worked examples, is written when that role is actually built) into the
   database, only if it's empty. All later reads/writes (profiles, role mapping, prompts, limits, gates)
   go through this store, never the yaml file directly.

9. **`appsmith config` CLI** (`appsmith/cli.py`, registered as the `appsmith` console script). Subcommands:
   `show`, `set-profile`, `set-role`, `show-prompt`, `set-prompt`, `reset-prompt`, `set-limits`,
   `set-gates`. Each accepts `--db-path` to target a database other than the default per-user one. This
   stands in for the Settings screen until M6.

10. **Manual real-endpoint script** (`scripts/manual_m1_check.py`, not part of the pytest suite). Runs
    the same `LLMClient.generate_structured` call the automated tests exercise with `FakeChatModel`,
    against a real OpenAI-compatible server (`--base-url`, `--model`), and prints the traced call(s).

## Acceptance check

- [x] `tests/test_graph_resume.py::test_two_node_graph_writes_artifact_and_traces_calls` — a two-node
      LangGraph (`greet` → `finalize`), checkpointed with LangGraph's `SqliteSaver`, runs under
      `FakeChatModel`, writes a versioned `GreetingArtifact` and `SummaryArtifact`, and records exactly
      one `llm_calls` row.
- [x] `tests/test_graph_resume.py::test_resume_after_simulated_crash_skips_completed_work` — after a
      full run, every in-memory object (graph, chat model, checkpointer, store, tracer) is thrown away
      and rebuilt from scratch against the same on-disk SQLite files, standing in for a process
      crash+restart, then the graph is invoked again with the same thread id and input. The LLM is not
      invoked a second time (asserted via a shared call counter, and by scripting the fresh
      `FakeChatModel` with only one response so a second call would raise), no new artifact version is
      written, and `llm_calls` still has exactly one row — because each node checks the artifact store
      before calling the LLM, not because of any particular LangGraph resume behavior (the test is
      written to hold regardless of whether LangGraph itself re-runs `greet` or skips straight to
      `finalize`).
- [x] `scripts/manual_m1_check.py` runs the same code path against a real local endpoint (manual,
      human-run; not part of CI, since CI has no GPU).
- [x] Full suite: `uv run pytest` (28 passed), `uv run ruff check .` (clean), `uv run mypy appsmith`
      (clean, 30 source files). `uv build` confirms `appsmith/defaults/` data files (the yaml and the
      `.j2` prompt placeholders) are actually included in the built wheel, not just readable from the
      source tree in dev mode.

## Notes / deviations

- `run_agent_loop` from spec section 7.1 is deliberately not implemented — see point 4 above.
- Per-kind artifact export paths (`docs/brief.json`, `components/<id>/spec.json`, etc. from the table in
  spec section 6) aren't wired up yet; the generic `docs/artifacts/<kind>/<id>/v<N>.json` convention is
  a placeholder until concrete artifact kinds exist starting in M2.
- `mypy --strict` is enforced on `appsmith/` only (matching the M0 CI workflow's `mypy appsmith`), not on
  `tests/` or `scripts/` — a few LangGraph/`ChatOpenAI` third-party typing quirks show up there
  (untyped `StateGraph` generics, `Pregel.invoke` overloads, `ChatOpenAI`'s `api_key: SecretStr`) that
  aren't worth fighting in test/manual-script code.
- `gh auth setup-git` (done during M0) was still in effect; no new credential issues this milestone.
