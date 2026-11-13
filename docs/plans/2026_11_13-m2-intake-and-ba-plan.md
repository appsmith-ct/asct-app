# M2: Intake and BA — Plan

Date: 2026-11-13
Status: **Done**

## Goal (from the spec, section 10)

> Intake chat graph that maintains a ProjectBrief and decides when it has enough to offer "Start
> build"; BA graph producing Requirements and Milestones with traceable IDs. CLI: `appsmith chat`,
> `appsmith run --stop-after ba`.
>
> Acceptance: on three sample briefs, the output validates, every requirement has at least one
> acceptance criterion, and every requirement belongs to exactly one milestone.

## What was done (all in `asct-be-engine`)

1. **`ProjectBrief`, `Requirement`, `Milestone` schemas** (`appsmith/artifacts/schemas.py`).
   `ProjectBrief` subclasses `Artifact` (versioned, one version per conversation turn).
   `Requirement` and `Milestone` are plain `BaseModel`s, not `Artifact` subclasses — the spec's
   artifact table stores a project's whole requirements list in one file
   (`docs/requirements.json`) and its whole milestones list in another, so the thing with an
   id/version/produced_by is the collection (`RequirementsArtifact`, `MilestonesArtifact`), not
   each item.

2. **Intake** (`appsmith/roles/intake.py`, `appsmith/graphs/intake_graph.py`). One LangGraph node,
   `intake_turn`, handles exactly one conversation turn: given the history so far plus the user's
   latest message, the model returns the *whole* updated brief (not a diff — more reliable for a
   small model than applying a patch) plus the next question, or a `ready_to_build` flag with
   nothing left to ask. The graph is compiled with a `SqliteSaver` keyed by `thread_id=project_id`;
   each turn only needs to pass the new `pending_user_message` as a *partial* input — confirmed
   empirically before relying on it (see "Notes" below) that LangGraph merges a partial `invoke()`
   input into the last checkpointed state for that thread, rather than requiring the full state
   every time. That's what makes a CLI process that exits between turns, or crashes, able to resume
   a conversation exactly where it left off just by invoking again with the same project directory.
   `IntakeContextBuilder` whitelists only `ChatTurn` items (the conversation history) — intake has
   nothing upstream to hide from, being the first role, but still goes through the same
   whitelist+budget `ContextBuilder` machinery as every other role, per spec section 2 decision 6.

3. **BA** (`appsmith/roles/ba.py`). One LLM call per project: given the frozen, ready brief, the
   model returns `milestones` and `requirements`, where each requirement names the one milestone
   it belongs to. Each milestone's `requirement_ids` list is **not** asked of the model — it's
   derived deterministically by grouping the requirements the model already produced, because
   trusting a small model to keep two cross-referencing lists in sync is a reliability risk the
   spec's techniques (section 7) exist to design around, and there's no need to take that risk when
   the aggregate is computable. A Pydantic `model_validator(mode="after")` on `BAOutput` checks
   every `requirement.milestone_id` against the milestone ids in the *same* response, raising
   `ValueError` on a dangling reference — this reuses `LLMClient`'s existing
   validate-and-retry-with-the-error-appended loop with no new machinery, the same way the spec's
   SA validator (section 5, point 7) is meant to work. `BriefNotReady` is raised if the BA is asked
   to run before a `ProjectBrief` with `ready_to_build=True` exists.

4. **Real system prompts** (`appsmith/defaults/prompts/{intake,ba}/system.md.j2`), replacing the M1
   placeholders — each with the role's constraints (intake never mentions technology; BA never
   mentions technology either, only WHAT) and one worked example, per spec section 7.6.

5. **CLI** (`appsmith/cli.py`): `appsmith chat <project>` runs the intake conversation (creates the
   project directory if missing, refuses to restart a conversation whose brief is already frozen,
   resumes an interrupted one via the checkpoint); `appsmith run <project> --stop-after ba` runs the
   BA step from the frozen brief. `--stop-after` only accepts `ba` for now — there's nothing past
   it yet. The core logic (`run_intake_chat`, `run_project_pipeline`) takes injectable
   `chat_model_factory`/`input_fn`/`print_fn` parameters so it's tested without a real terminal or
   model endpoint; `_cmd_chat`/`_cmd_run` pass those through as explicit keyword arguments sourced
   from module-level names (not relying on the wrapped functions' own defaults) specifically so that
   tests can monkeypatch `appsmith.cli.default_chat_model_factory` / `builtins.input` and have it
   actually take effect — a default *parameter* value is bound once, at `def` time, so monkeypatching
   the name afterward does nothing to an already-bound default.

6. **Sample briefs** (`appsmith/eval/sample_briefs.py`). The three examples the spec names for M8's
   eval harness (section 10) — a to-do app, a URL shortener, an inventory system — added now,
   ahead of that harness, because M2's acceptance check explicitly needs them. Brief *content*
   only, reusable by M8 without change.

## Acceptance check

- [x] `tests/test_sample_briefs_ba.py` — on all three sample briefs: BA's output validates against
      `BAOutput`'s schema and cross-reference check, every requirement has at least one acceptance
      criterion (Pydantic `min_length=1` on `acceptance_criteria`), and every requirement belongs to
      exactly one milestone (structurally guaranteed by `milestone_id: str` being a single field,
      checked to reference a real milestone).
- [x] `appsmith chat` / `appsmith run --stop-after ba` both exist and work, tested at three levels:
      the underlying graphs/nodes directly (`test_intake_graph.py`, `test_ba_node.py`), the CLI's
      testable wrapper functions (`test_cli_chat_and_run.py`), and `main()` itself with argparse
      parsing real argv (`test_cli_chat_and_run_argv.py`).
- [x] Resumability: `test_intake_graph.py::test_resume_after_crash_continues_same_conversation`
      throws away every in-memory object after turn 1 and rebuilds from scratch against the same
      checkpoint file, then continues the conversation to completion — the prior turn's history
      carries over and the already-asked question is not re-asked.
- [x] Full suite: `uv run pytest` (42 passed), `ruff check .` (clean), `mypy appsmith` (clean, 35
      source files).

## Notes / deviations

- Before building the multi-turn chat loop, verified empirically (a throwaway script, not kept)
  that `compiled.invoke({"pending_user_message": answer}, config)` on a thread with prior
  checkpointed state merges that partial dict into the existing state rather than overwriting
  everything else back to field defaults — this is the mechanism the whole resumable-chat design
  depends on.
- Found and fixed a real bug while writing the first multi-turn FakeChatModel test: `LLMClient`
  called its `chat_model_factory` fresh on every `generate_structured()` call, so a stateful
  `FakeChatModel` (which hands out its next scripted response per call) would silently restart from
  its first response every call instead of advancing — invisible in M1 because every M1 test only
  ever made one `generate_structured` call per `LLMClient`. Fixed by caching one chat model instance
  per `ModelProfile.id` inside `LLMClient`, which also avoids reconstructing a real `ChatOpenAI`
  client on every call in production.
- `gate_ba` (the optional, default-off human approval gate after BA) is **not** implemented — a
  gate needs something to pause *for*, and nothing can act on that pause until an approval
  mechanism exists (at least an interrupt/resume story, realistically the UI in M6). Adding the node
  now would be a no-op with no test worth writing. `gate_sa` (default-on) is the one that actually
  needs this and arrives with the Software Architect in M3.
- Per-kind artifact export file paths matching the spec's exact names (`docs/brief.json`,
  `docs/requirements.json`, `docs/milestones.json`) are still not wired up — artifacts export to the
  generic `docs/artifacts/<kind>/<id>/v<N>.json` convention established in M1. Worth revisiting once
  SA's `ComponentSpec`/`Contract` exports (M3) make the full per-kind path table worth building once
  rather than piecemeal.
