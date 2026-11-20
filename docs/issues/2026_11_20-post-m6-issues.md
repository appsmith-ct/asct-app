# Open issues — recorded 2026-11-20, to be fixed after M7

Three issues found by using the app against a real local model after M6 closed. None of them block
M7 (the milestone loop and change requests, which is engine-side pipeline work), so they're
recorded here and scheduled for right after it. Each entry is written so it can be picked up
cold: symptom as observed, the actual cause traced in the code, what the fix is, and how to know
it's done.

Status key: **Open** = not started, **Fixed** = done and verified. Update the status line in
place as these get fixed.

**All three were fixed on 2026-11-20**, in the order below. Driving the retargeted model for real
(building a to-do app, as asked) then surfaced four further bugs that no amount of reading could
have found — they're recorded under ISSUE-3's "What the real model actually exposed", because
that's where they came from.

---

## ISSUE-1 — Chat messages don't survive a page refresh or navigation

**Status:** **Fixed** 2026-11-20 (engine `0127a95`, UI `81ec96a`)
**Area:** `asct-fe-desktop` (primary), `asct-be-engine` chat WS (needs one new field)
**Severity:** Major — looks like data loss to the user; the brief is actually intact, only the
transcript is gone.

### Symptom

Open a project's Chat screen, have a few turns with the intake agent, then either refresh the page
or navigate to another screen (Pipeline, Artifacts, …) and come back. Every message is gone. The
conversation continues correctly from where it left off — the agent asks the *next* question, not
the first one — but the history above it is blank.

### Cause

The transcript only ever existed in React state. [Chat.tsx:31](../../asct-fe-desktop/src/pages/Chat.tsx#L31)
holds it as `const [turns, setTurns] = useState<Turn[]>([])`, appended to by the user's own `submit()`
and by the `question?.seq` effect. Nothing reads it back from anywhere on mount, so a remount starts
empty.

The data itself is not lost. The engine keeps the full transcript in the intake graph's LangGraph
checkpoint: `IntakeState.history` is a `list[ChatTurn]`
([intake.py:44-56](../../asct-be-engine/appsmith/roles/intake.py#L44-L56)), accumulated every turn
and checkpointed per project under the `intake` checkpoint file. The chat WS already loads exactly
that state on connect (`_get_or_init_state`,
[chat.py:63](../../asct-be-engine/appsmith/api/routers/chat.py#L63)) and sends it to the client —
but `send_state` ([chat.py:124](../../asct-be-engine/appsmith/api/routers/chat.py#L124)) builds a
`ChatTurnMessage(kind=..., text=..., brief=state)` whose `text` is only the *next question*. The
`history` list is sitting right there in `state` and is never surfaced as something the client can
render.

So this is one missing field on the wire plus one missing hydration step in the UI, not a
persistence gap.

### Fix

1. Engine: add `history` to `ChatTurnMessage` (`appsmith/api/schemas.py`) and populate it from
   `state["history"]` in `send_state`. It's already a list of `{role, content}` dicts, so no new
   schema work beyond the field itself. Re-export `docs/api/openapi.json` afterwards — note the WS
   frame schema is the part the UI's generated types care about here, so check that the export
   actually covers it rather than assuming.
2. UI: on the first frame of a connection, replace `turns` with the server's `history` instead of
   appending to it. The cleanest shape is for `useChatSocket` to own the turn list (it already owns
   `question`/`brief`/`readyToBuild`) and hand it to `Chat.tsx` ready to render, which also removes
   the current duplication where the UI appends the user's own message locally *and* the server
   records the same message in `history`.
3. Watch the de-dup carefully: `history` records the assistant turn as `"(ready to build)"` once
   the brief is frozen ([intake.py:170](../../asct-be-engine/appsmith/roles/intake.py#L170)),
   which should not be rendered as a chat bubble — the UI has its own "Brief is ready to build"
   banner for that.
4. Keep the `question.seq` identity trick that the post-M6 fix introduced (two consecutive
   identical questions are two distinct turns) — hydrating from `history` must not reintroduce
   text-equality de-duplication.

### Done when

A Playwright step in `e2e/smoke.spec.ts` chats two turns, reloads the page, and asserts both prior
turns are still rendered; and the same after navigating to Pipeline and back.

---

## ISSUE-2 — The Observability block is hard to read; rebuild it as an OpenCode-style modal

**Status:** **Fixed** 2026-11-20 (engine `56ff576`, UI `c113417`)
**Area:** `asct-fe-desktop` (primary), `asct-be-engine` (timestamps + context-window numbers)
**Severity:** Major usability — this panel is the main window into *why* a small model did what it
did, and right now it's the least legible part of the app.

### Symptom

The Chat screen's Observability card
([Chat.tsx:158-172](../../asct-fe-desktop/src/pages/Chat.tsx#L158-L172),
[CallObservability.tsx](../../asct-fe-desktop/src/components/CallObservability.tsx)) crams
reasoning, prompt and response into three stacked `max-h-32`/`max-h-48` `<pre>` boxes inside a
panel that is itself a scrolling sidebar column at `col-span-2` of a 5-column grid. Three nested
scroll regions, no timestamps, no sense of where the context window stands. Reading one call means
scrolling inside a box inside a box.

### What's wanted instead

The OpenCode model: observability is a **modal/overlay**, not a sidebar, and it has two parts.

1. **A context-window summary.** How much of the model's context the current conversation is
   using, against the profile's configured `ctx`. With a 32768-token window and a thinking model
   that can burn ~2000 reasoning tokens for a one-sentence reply, "how close am I to the edge" is
   the single most useful number on the screen and today it's nowhere.
2. **A list of all raw requests**, each one expandable to the full detail (system prompt,
   rendered messages, reasoning, raw response, token counts, latency, validation outcome, retry
   index, profile). **Every entry must be timestamped** — this is called out explicitly; the
   current panel has no notion of when anything happened, which makes it impossible to line a call
   up against what you were doing at the time.

### What the engine already provides, and what it doesn't

`GET /runs/{run_id}/llm-calls` already returns everything the detail view needs *except* a
timestamp — and the timestamp **already exists in the database**. `LLMCallRow.created_at` is a
non-nullable column ([tracing_orm.py:29](../../asct-be-engine/appsmith/core/tracing_orm.py#L29)),
so **no migration is needed**. It's simply dropped on the way out: the `CallRecord` dataclass
([tracing.py:21-34](../../asct-be-engine/appsmith/core/tracing.py#L21-L34)) has no `created_at`
field, so `CallTracer.list_calls` can't carry it, and `LLMCallSummary`
([schemas.py:85](../../asct-be-engine/appsmith/api/schemas.py#L85)) doesn't expose it. The fix is
to add the field to both and pass it through `list_llm_calls`
([runs.py:190-206](../../asct-be-engine/appsmith/api/routers/runs.py#L190-L206)), then re-export
the OpenAPI document. Note `CallRecord` is also the *write* path (`CallTracer.record` sets
`created_at` itself) — make the field optional on write so no caller has to supply it, and
populate it on read.

Context-window numbers need:
- the role's profile `ctx` (available from `GET /settings/models`), and
- a running total of prompt tokens for the conversation. `input_tokens`/`output_tokens` on each
  call are `approx_tokens` estimates (`appsmith/core/tokencount.py`), not server-reported counts —
  fine for a gauge, but the UI must label it as approximate rather than implying an exact count.

### Fix sketch

- Engine: thread the existing `created_at` through `CallRecord` → `LLMCallSummary` (+ openapi
  re-export). No migration.
- UI: replace the sidebar card with a trigger (a compact status strip — e.g. "12 calls · ~18.4k /
  32k ctx") that opens a `Dialog` (`components/ui/dialog.tsx` already exists). Inside: the context
  gauge on top, then a timestamped, newest-first request list, each row expandable.
- Keep `LiveTurn` exactly as it is. The live streaming turn inside the chat bubble is working and
  is a *different* concern (what's happening right now) from the call log (what happened). Don't
  fold one into the other.
- The same modal should be reusable from the Runs screen, which has the same raw-call-inspection
  need for non-intake roles — design it to take a list of calls plus a profile, not to be
  chat-specific.

### Done when

The Chat screen shows no stacked-scroll observability panel; the modal shows per-call timestamps
and a context-window figure against the active profile's `ctx`; and a screenshot via
`scripts/interact-and-shot.mjs` confirms it against a real model, not just the fake-LLM path.

---

## ISSUE-3 — Retarget defaults from bonsai-27b to Qwen3.6-35B-A3B, and fix what made the old model loop

**Status:** **Fixed** 2026-11-20 (`0127a95`, plus follow-ups) — see the section at the end
for what driving the real model then exposed.
**Area:** `asct-be-engine` — `appsmith/defaults/roles.yaml`, `appsmith/defaults/prompts/*`,
`appsmith/core/llm_client.py`, `appsmith/api/deps.py` / `appsmith/cli.py` chat-model factories
**Severity:** Major — the shipped defaults name a model that was abandoned for being unusable.

### Symptom

`bonsai-27b` at 1-bit quantization reliably got stuck in a thinking loop: it would emit reasoning
tokens indefinitely rather than converging on an answer. The user switched to
`Qwen3.6-35B-A3B-UD-Q3_K_M` with a 32768-token context window. The shipped defaults still point at
the old model.

### Part A — the defaults

[roles.yaml](../../asct-be-engine/appsmith/defaults/roles.yaml) declares exactly one profile,
`bonsai-27b-1bit` (`model: bonsai-27b`, `ctx: 32768`, `tools: native`, `temperature: 0.2`), and
maps all eight roles to it, four of them with `thinking: true`.

Replace it with a profile for `Qwen3.6-35B-A3B-UD-Q3_K_M` at `ctx: 32768`. The llama.cpp server in
use is reachable at **`http://192.168.1.3:8080/v1`** (not the `127.0.0.1` the old default assumed —
it runs on another machine on the LAN). Whether the shipped default should hardcode a LAN address
or stay on loopback is a judgement call: loopback is the right *shipped* default for anyone else
cloning the repo, so the likely answer is keep `127.0.0.1:8080/v1` in `roles.yaml` and set the real
address per-machine via `appsmith config` / the Settings screen. Record whichever way it goes, and
make sure the Settings screen's "test connection" button works against a non-loopback host.

Two more things to get right while doing it:

- **`roles.yaml` is a first-run seed only.** `SettingsStore.seed_defaults_if_empty`
  ([settings_store.py:46](../../asct-be-engine/appsmith/core/settings_store.py#L46)) writes it into
  the settings database once and never looks at the file again. Editing the YAML will do nothing
  for an existing install — the fix has to account for already-seeded databases (either a
  documented reseed/`appsmith config` path, or a migration that renames the profile). Don't ship a
  change that silently only works on a fresh machine.
- **Profile ids are referenced by role mappings.** Renaming the profile key means every
  `role_mappings.profile_id` row has to move with it.

### Part B — why the loop happened, beyond the model's own weights

Two real gaps in the engine made a looping model much worse than it had to be, and both should be
fixed as part of this, because they'll bite the new model too:

1. **No generation cap at all.** `default_chat_model_factory`
   ([deps.py:22-32](../../asct-be-engine/appsmith/api/deps.py#L22-L32)) passes only `base_url`,
   `model`, `temperature` and a dummy api key. There is no `max_tokens`, and `ModelProfile.ctx`
   is never sent to the server in any form. A model that decides to think forever is given no
   reason to stop. A `max_tokens` derived from the profile (and surfaced as a profile field) is
   the direct fix.
2. **The per-role `thinking` switch is dead config.** `RoleConfig.thinking`
   ([model_profile.py:40](../../asct-be-engine/appsmith/core/model_profile.py#L40)) is parsed,
   stored in the settings db, editable from the CLI and Settings screen — and read by *nothing*.
   `grep -rn "thinking" --include=*.py appsmith/` finds only config plumbing, never a request. For
   Qwen3-family models, thinking is controlled server-side via
   `chat_template_kwargs: {"enable_thinking": false}` (llama.cpp / vLLM), so "turn thinking off for
   the dev roles" is expressible — the switch just needs to be wired through the chat-model
   factory into `extra_body`. Being able to turn thinking *off* per role is the most direct lever
   against a thinking loop, and it's a switch the project already pretends to have.

### Part C — the JSON-output question (what's actually going on)

The user's question was: *why do our system prompts specify JSON output — don't these models just
send JSON when calling tools?* The short answer: **this engine never uses native tool-calling, so
there are no model-side "tool calls" to produce JSON.** There are three distinct mechanisms here
and it's worth having them written down:

1. **Constrained decoding.** `LLMClient._bind_schema`
   ([llm_client.py:200-213](../../asct-be-engine/appsmith/core/llm_client.py#L200-L213)) binds
   `response_format: {"type": "json_schema", "json_schema": {..., "strict": true}}` on *every*
   call. Where the server honours it (llama.cpp's grammar-constrained sampling, vLLM's guided
   decoding), the model physically cannot emit non-conforming output. This is the real guarantee.
2. **The `json_action` tool protocol.** `run_agent_loop`
   ([agent_loop.py:1-10](../../asct-be-engine/appsmith/core/agent_loop.py#L1-L10)) does tool use by
   asking the model for one `AgentAction` JSON object per turn (`{"tool_call": {...}}` or
   `{"done": true}`), validated by Pydantic. It does this *regardless* of a profile's `tools`
   strategy — `ToolStrategy.NATIVE` exists in the schema but nothing implements it, and
   `roles.yaml` setting `tools: native` today has no effect. So the OpenAI `tools`/`tool_calls`
   fields are never sent and never parsed. Nothing is going to hand us JSON on its own.
3. **The prompt instruction.** "Respond with JSON only, matching the given schema. No prose
   outside the JSON" appears at the end of each role prompt (e.g.
   [intake/system.md.j2:29](../../asct-be-engine/appsmith/defaults/prompts/intake/system.md.j2#L29)).
   This is belt-and-braces for servers that ignore `response_format`, and it is *not* redundant
   with mechanism 1 in practice — a quantized local server silently dropping the grammar is a real
   failure mode.

So the instruction stays. What should change for the new model:

- **Decide and document whether `tools: native` means anything.** Qwen3 has a proper tool-calling
  template and `Hermes`-style parsers are widely supported. Either implement the native path or
  change the default profile to `tools: json_action` so the config stops lying. Recommendation:
  set `json_action` now (truthful, zero risk) and treat native tool-calling as its own later task
  — it's a deferred optimization per the engine's CLAUDE.md, not a bug.
- **Verify `strict: true` + full `model_json_schema()` actually works on this server.** Pydantic
  emits `$defs`/`$ref` for nested models (`AgentAction.tool_call`, `ComponentSpec.stack`, …).
  Confirm the llama.cpp build in use accepts that, directly against the endpoint, before tuning
  anything else — if it quietly falls back to unconstrained sampling, every other symptom here
  gets reinterpreted.
- **Prompt tuning for Qwen3.** Concretely: the worked examples in the prompts are fenced
  ```` ```json ```` blocks, which invites a model to reproduce the fence (fine under grammar
  constraint, broken without it). Check whether the reasoning-heavy roles need the examples at all
  once thinking is on, and whether the prompts fit comfortably inside 32k alongside the context
  the `ContextBuilder` adds — `IntakeContextBuilder`'s `token_budget` is a hardcoded `4000`
  ([intake.py:140](../../asct-be-engine/appsmith/roles/intake.py#L140)), unrelated to the
  profile's real `ctx`, which is its own small inconsistency worth folding in.

### Done when

`roles.yaml` names the Qwen profile; an already-seeded settings database ends up on the new profile
too (by a documented path, tested); `max_tokens` and the per-role `thinking` switch both reach the
server; and `scripts/manual_m*_check.py`-style manual verification against the real endpoint shows
intake completing a brief without a runaway reasoning stretch. FakeLLM suite stays green throughout
(none of this is reachable from the fake path, so expect to verify Part B by asserting on what the
factory *constructs*, not by calling a model).

---

## Fix order (as executed)

ISSUE-3 first, as planned — it changed what every other manual verification ran against, and a
working model default is what made the other two testable for real. Then ISSUE-1 (small,
self-contained), then ISSUE-2, which benefited from ISSUE-3's timestamp and context-window work
being settled first. The ordering held up: most of the real discoveries below came out of ISSUE-3
and would have been invisible had it been done last.

---

## What the real model actually exposed (2026-11-20)

Retargeting to Qwen3.6-35B-A3B was the easy half. Driving the app to build a to-do list app
against it found four bugs, three of which are invisible to the FakeLLM suite by construction.
Recorded here because the *method* generalises: a scripted fake agrees with whatever the engine
expects, so the only way to find these is to run the real thing and read the call trace.

**Measured first, before changing anything** (all against the real endpoint):

| Question | Answer |
| --- | --- |
| Does `json_schema` + `strict` + `$defs`/`$ref` constrain output? | Yes — clean, valid, validates |
| Does `chat_template_kwargs: {enable_thinking: false}` work? | Yes — 301 tokens/8.7s → 3 tokens/0.3s |
| Does `max_tokens` cap generation? | Yes — but the model can spend it all reasoning and return **empty content** |
| Does an arbitrary `model` name work? | Yes — llama.cpp ignores it and serves what it was started with |

### 1. A response that hit the token limit crashed the whole run

With `response_format` bound, the openai SDK raises `LengthFinishReasonError` instead of
returning what was generated, and that escapes `generate_structured`'s retry loop. Not an edge
case: the same intake prompt produced **738–3055 completion tokens across four identical calls**,
and the real run hit a single turn that burned **30,559 characters of reasoning over 211 seconds**
and returned nothing. Now degrades to a traced `length_limit` attempt plus a retry that tells the
model it was cut off — which recovered that exact turn in 16.7s.

### 2. Under constrained decoding, a defaulted field is one the model may skip

The JSON Schema *is* the grammar, and a Pydantic field with a default isn't in `required`. The
model may omit it; Pydantic then fills the default, and the engine cannot distinguish "the model
said none" from "the model never said". This was silently costing real work in two places:

- the SA omitted `requirement_ids`, failed coverage validation, and **failed identically on all
  three retries** — retrying cannot help, because the grammar still permitted the omission;
- intake omitted `features`, so a brief listing three features on turn 1 had **none** by the end.

Every LLM-facing output schema is now fully required, `| None` where absence is meaningful.

### 3. Intake was never shown its own previous brief

It is asked for the whole updated brief every turn, but its context held only the raw chat — so
each turn it re-derived every field from the transcript, and dropped things. It now gets the brief
as state alongside the system prompt. After the fix the same conversation kept
`features=['add tasks', 'mark tasks as done', 'delete tasks']` end to end.

### 4. The SA confused requirement ids with milestone ids

Requirements and milestones were rendered into one merged list, and the model put `["M1", "M2"]`
in a component's `requirement_ids`. Fixed at the source (two labelled sections, with the rule
stated in the heading of each) rather than by asking the prompt to talk the model out of it, plus
a validator message that names the likely mistake instead of only the symptom.

### Prompt changes, and why

- **Intake convergence.** The agent asked six questions and never set `ready_to_build`, despite
  the user saying "nothing else, start building" three times. Added an explicit override rule for
  that case and a four-question ceiling. Result: four turns instead of six-and-counting.
- **Brevity.** Both intake and the SA were told to think briefly and why (wall-clock cost to the
  user, no better answer). 20–30k characters of reasoning for one scoping decision is the tail
  this is aimed at.

### Where it ended up

`uv run python scripts/manual_pipeline_check.py "a simple to-do list web app ..."` now runs
**intake → BA → SA green against the real model**, producing a traceable set of requirements, two
milestones, and a backend/frontend architecture with a contract between them. Before these fixes
the same command crashed during intake and then failed the SA three times.

Still open, not pursued here:

- **Reasoning volume is the dominant cost.** Individual calls still spend 3k–30k characters
  thinking. The levers that exist (per-role `thinking`, `max_tokens`, prompt wording) are now all
  wired; what is not yet tried is turning thinking *off* for the SA and BA, which an early probe
  suggested is noticeably cheaper but produced a thinner brief for intake.
- **The component build (Tech Lead, Developers, QA) has not been driven against the real model
  yet** — only intake, BA and SA. That path is where the agent loop and the tool jail live, and
  it is the obvious next thing to exercise.
