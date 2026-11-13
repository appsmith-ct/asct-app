# M3: Software Architect — Plan

Date: 2026-11-13
Status: **Done**

## Goal (from the spec, section 10)

> SA graph producing Architecture, ComponentSpecs, Contracts and stack choices, with a default
> decision order (see section 5) and a validator that rejects dangling references, uncovered
> requirements and cyclic dependencies.
>
> Acceptance: validator tests pass; on the sample briefs every requirement maps to a component,
> and each ComponentSpec's ContextBuilder output excludes other components' specs.

## What was done (all in `asct-be-engine`)

1. **Stack profile registry** (`appsmith/core/stack_profile.py`, `appsmith/core/stacks.py`,
   `appsmith/defaults/stacks/{python-fastapi,typescript-react}.yaml`). The spec's decision order
   step 4 says "pick a stack... from `config/stacks/*.yaml`" — a selection from a known registry,
   not something invented per component. The SA's prompt is given the available stacks by id;
   the model picks `stack_id`, never free-text language/framework.

2. **New artifact schemas** (`appsmith/artifacts/schemas.py`): `StackChoice`, `ComponentSpec`,
   `Contract`, `Architecture`. `ComponentSpec` and `Contract` subclass `Artifact` directly (one
   store row per component/contract id) rather than living inside a collection artifact, matching
   the spec's `components/<id>/spec.json` and `contracts/<id>.*` per-item file convention — the
   opposite shape from `RequirementsArtifact`/`MilestonesArtifact` (M2), which collect many items
   into one file.

3. **SA role** (`appsmith/roles/sa.py`). One LLM call (`SAOutput`) covers decision-order steps 1-6:
   domain entities, style, contracts, stack choice, deployment, and per-component
   `definition_of_done` + `requirement_ids`. Step 7, the architecture validator, splits across two
   mechanisms:
   - **Self-contained checks** — no contract naming an unknown component id, no cycle in the
     component dependency graph (a consumer depends on its contract's producer) — are a Pydantic
     `model_validator(mode="after")` on `SAOutput`, which reuses `LLMClient`'s existing
     retry-with-the-error-appended loop with no new machinery, the same pattern as BA's milestone
     cross-check (M2).
   - **The one check that needs external data** — no requirement left uncovered — can't be a
     self-contained validator, because `SAOutput` doesn't carry the real requirements list. This
     is what motivated adding `extra_validate` to `LLMClient.generate_structured` (see below).

   Each component's `inputs`/`outputs` (contract ids) are derived from which contracts name it as
   producer/consumer, not asked of the model — the same reliability reasoning as BA's
   `milestone.requirement_ids` (M2): don't trust a small model to keep two cross-referencing lists
   in sync when one is mechanically derivable from the other.

   `ComponentContextBuilder` previews what a Tech Lead will see for one component (the real
   version arrives with the Tech Lead role in M4): its `gather_items()` only ever fetches that one
   component's own `ComponentSpec` and the `Contract`s naming it — never another component's data
   — which is what the M3 acceptance check on isolation exercises directly.

4. **`LLMClient.generate_structured` gained an `extra_validate` hook** (`appsmith/core/llm_client.py`).
   Runs after schema validation succeeds; raises `ValueError` to trigger the same retry-with-error
   behavior as a Pydantic validation error. This is for exactly the "needs data the model's own
   JSON can't see" case — the uncovered-requirements check here — and is a small, backward-
   compatible, optional addition (default `None`) that M2's and M1's call sites are unaffected by.

5. **Real SA system prompt** (`appsmith/defaults/prompts/sa/system.md.j2`), replacing the M1
   placeholder — the 7-step decision order as instructions, plus one worked example.

6. **CLI**: `appsmith run` now runs `ba` then `sa`; `--stop-after` genuinely pauses the graph there
   via LangGraph's `interrupt_before` (verified empirically beforehand — see "Notes" below) rather
   than relying on there being nothing left to run, which is what made `--stop-after ba` a no-op in
   M2 (there was only one node).

## Acceptance check

- [x] **Validator tests pass** — `tests/test_sa_node.py` covers each validator path directly: an
      uncovered requirement, a contract naming an unknown component, a dependency cycle, and an
      unknown `stack_id`, each one caught on the first attempt and successfully retried on the
      second (scripted via `FakeChatModel`).
- [x] **On the sample briefs, every requirement maps to a component** —
      `tests/test_sample_briefs_sa.py`, parametrized over the same three sample briefs BA's M2
      acceptance check uses: runs BA then SA against each, and asserts the union of every
      component's `requirement_ids` equals the full requirement id set.
- [x] **Each ComponentSpec's ContextBuilder output excludes other components' specs** —
      `tests/test_component_context_builder.py`: builds `ComponentContextBuilder` for one of two
      saved components and asserts the other component's (deliberately distinctive) responsibility
      text never appears in the built context, in both directions, plus that an unknown component
      id yields an empty context.
- [x] Full suite: `uv run pytest` (59 passed), `ruff check .` (clean), `mypy appsmith` (clean, 38
      source files).

## Notes / deviations

- Before building `--stop-after`'s real pause behavior, verified empirically (a throwaway script)
  that `compiled.invoke(input, config, interrupt_before=[...])` pauses before the named node and
  that a later `compiled.invoke(None, config, interrupt_before=[])` resumes and completes it — the
  same kind of upfront check used for the partial-input-merge behavior in M2.
- **Found and fixed a real bug while wiring `--stop-after` resume logic**: `run_intake_chat` and
  `run_project_pipeline` both use `thread_id=project_id`, and until this milestone they also shared
  one checkpoint SQLite file. `run_project_pipeline`'s new `compiled.get_state(config)` check (to
  decide "fresh start" vs. "resume") would pick up the *intake* graph's leftover checkpoint under
  that same thread id — a checkpoint from a completely different graph shape — and wrongly treat
  the project graph as already-started. Fixed by giving each graph its own checkpoint file:
  `project_checkpoint_db_path(project_root, graph_name)` now takes a `graph_name` argument. Worth
  remembering for any future graph that reuses a project's thread id.
- `gate_sa` (default-on in `roles.yaml`) is still not implemented, for the same reason `gate_ba`
  wasn't in M2: `sa` is still the last node in the project graph, so there's nothing after it yet
  for a gate to protect entry into. It becomes load-bearing once `fan_out_components` exists in
  M4, which is when it's actually built.
- Per-kind artifact export file paths matching the spec's exact names (`docs/components/<id>/spec.json`,
  `docs/contracts/<id>.*`) are still not wired up — same generic
  `docs/artifacts/<kind>/<id>/v<N>.json` convention from M1/M2. `Contract.schema_ref` points at a
  conventional `contracts/<id>.json` path that nothing writes yet; actual OpenAPI/JSON Schema
  authoring for a contract is a Tech Lead/M4-era concern, not something M3's architecture decision
  step produces itself.
- `LLMClient`'s per-profile chat-model cache (added in M2) turned out to matter again here: `ba`
  and `sa` share the same default profile id (`bonsai-27b-1bit`), so a test driving both steps
  through one `chat_model_factory` must script both responses on the *same* `FakeChatModel`, in
  call order — documented in the new CLI tests' comments.
