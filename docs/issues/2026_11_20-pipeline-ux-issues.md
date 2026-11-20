# Pipeline screen UX issues — recorded 2026-11-20

Found by using the Pipeline screen against a real model after the post-M6 fixes landed. Intake now
completes reliably; everything *after* intake is where the UX falls apart.

These are one cluster, not six unrelated bugs. The Pipeline screen was built in M6 against a
FakeLLM engine where every node finishes in milliseconds, so "what is happening right now" never
had to be answered — the run was over before you could look. Against a real model a single node
takes minutes, the page gets refreshed mid-run, and the screen has nothing to say.

Status key: **Open** = not started, **Fixed** = done and verified.

---

## ISSUE-4 — Run progress is invisible, and a refresh loses it entirely

**Status:** Open
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`, `src/api/useRunEvents.ts`; engine events WS
**Severity:** Blocker for actually watching a run — this is the screen's whole job.

### Symptom

> I cannot initiate the pipeline run. The run button has disappeared from the pipeline page. First
> there was nothing in the pipeline page, after a few refreshes I saw that a single BA turn has
> run. I think the engine is running in the background but the FE is not properly showing them.

Two distinct things, which is why it reads as confusing rather than simply broken.

### Cause A — the Start button is correctly hidden, for an invisible reason

`Chat.tsx`'s **Start build** already does `POST /projects/{id}/runs` before navigating to
Pipeline, so by the time the Pipeline screen loads, a run is active. The button is gated on
`{!runStatus && ...}` ([Pipeline.tsx:225](../../asct-fe-desktop/src/pages/Pipeline.tsx#L225)), so
it correctly disappears — but the only trace of *why* is the words `status: running` in small grey
text in the subtitle. The screen looks empty and unstartable, which is indistinguishable from
broken.

### Cause B — progress exists only in a live event stream with no replay

This is the real bug. `useRunEvents` opens `WS /runs/{id}/events` on mount and builds `nodeStatus`
purely from `node_started`/`node_finished` frames **as they arrive**
([useRunEvents.ts:50-58](../../asct-fe-desktop/src/api/useRunEvents.ts#L50-L58)). The engine's
`EventBus` has no backlog and the WS sends no snapshot on connect, so:

- opening the Pipeline screen *after* `ba` started means its `node_started` is already gone — the
  node sits at `idle` for the entire minutes-long call;
- every page refresh wipes `nodeStatus` back to `{}` and starts over.

`resolvedStatus` back-fills only for `paused_at_gate`, `done` and `failed`
([Pipeline.tsx:116-147](../../asct-fe-desktop/src/pages/Pipeline.tsx#L116-L147)) — there is
deliberately no case for `running`, because when it was written nothing was ever observably
running. That is why a refresh eventually "showed that a single BA turn has run": the user hit a
refresh at the moment the gate was reached, and the `paused_at_gate` fallback finally marked
`ba`/`sa` as done.

### Fix

1. The engine should be able to answer "where is this run now?" over REST, not only as a live
   stream — `GET /runs/{id}` already returns `status`/`next_gate`; it should also return the
   per-node state the UI is trying to reconstruct. Deriving it from stored artifacts (as
   `GET /runs/{id}/milestones` already does) makes it survive an engine restart too.
2. Failing that, at minimum: a `running` case in `resolvedStatus` that marks the first
   not-yet-finished node as running, and a replay of recent events when the events WS connects.
3. Say plainly that a run is in progress, where the Start button used to be — not in subtitle
   grey. Offer the Start button whenever there is genuinely no active run.

---

## ISSUE-5 — Clicking "Build milestone" shows the intake conversation's LLM calls

**Status:** Open
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Minor, but actively misleading — it attributes work to the wrong node.

### Cause

[Pipeline.tsx:322](../../asct-fe-desktop/src/pages/Pipeline.tsx#L322):

```ts
if (selectedNode === 'build_milestone') return callNode !== 'ba' && callNode !== 'sa'
```

A catch-all written when the only LLM-calling nodes were `ba`, `sa` and the component build. It is
false for `intake_turn`, so every intake call matches too. `GET /runs/{id}/llm-calls` deliberately
unions calls traced under the project id (which includes intake) with calls traced under each
component id, so intake calls are right there in the list.

### Fix

Match by what a node actually owns rather than by exclusion — the component-build nodes have known
names (`tl_plan`, `dev_implement`, `tl_review`, `component_e2e`, `handoff`, `qa_test_plan`, ...).
This disappears anyway if ISSUE-7 is done, because each sub-step would own its own calls.

---

## ISSUE-6 — No indication of what is running, or whether anything is happening at all

**Status:** Open
**Area:** engine (`appsmith/api/run_manager.py`, events WS), `asct-fe-desktop`
**Severity:** Major — the difference between "working" and "hung" is currently unknowable.

### Symptom

> There was no indication which part of the pipeline was currently running, until the agent hit an
> approve gate. Once I approved it then there was a rotating wheel. Even then I am not sure if the
> agent is stuck or doing something.

That uncertainty is well-founded: a single call legitimately takes **211 seconds** (measured — one
intake turn spent 30,559 characters on reasoning). A spinner that means "somewhere between 2 and
240 seconds, or hung forever" conveys almost nothing.

### What's wanted

> I think it is better to display the streaming reasoning and outputs per request in each step.

The engine can already do this and doesn't, for runs. `LLMClient.generate_structured` takes an
`on_delta` callback and the **Chat screen already streams reasoning and answer token by token**
through it — but `run_manager` constructs its `LLMClient` without one, so a run emits only coarse
`node_started`/`node_finished` events plus an `llm_call_recorded` *after* each call completes.

### Fix

Thread `on_delta` through the run path the way the chat WS does, and add a delta frame to the run
events WS. The Chat screen's `LiveTurn` component already renders exactly this (reasoning block,
answer, ticking tokens/elapsed/tok-per-sec) and should be reusable as-is. The ticking elapsed
counter matters as much as the text: it is what distinguishes slow from stuck.

---

## ISSUE-7 — "Build milestone" is a whole graph shown as one box

**Status:** Open
**Area:** engine (no events emitted inside the milestone flow), `asct-fe-desktop`
**Severity:** Major — this node is where almost all the time goes.

### Symptom

> The "Build Milestone" is itself its own graph. So I would like to see that expanded and which
> step inside that subgraph [is running].

Correct, and it is the largest part of a run by far. Behind that one box:

- `fan_out_components` → per component: `tl_plan` → `scaffold` → task loop
  (`dev_implement` → `run_gates` → `tl_review`, with an escalation ladder) → `component_e2e` →
  `handoff`
- then `integrate_stage` → `stage_components` → `qa` → `triage_bugs`, looping up to
  `bugfix_rounds` times.

### Cause

`wrap_node_with_events` is applied only to the **project graph's** nodes
(`appsmith/api/run_manager.py`), so nothing inside `build_and_verify_milestone` publishes
anything. The component subgraph is a real LangGraph graph but runs unobserved; the only live
signal from inside it is `llm_call_recorded`, whose `node` field does carry `tl_plan`,
`dev_implement` etc.

### Fix

Publish node events from inside the milestone flow and the component subgraph (an `EventBus` is
already threaded as far as `LLMClient`; the node wrappers need the same treatment), then render
`build_milestone` as an expandable group in React Flow. `GET /runs/{id}/milestones` already
reports per-milestone component scope, so the static shape is available even before the run
reaches it.

---

## ISSUE-8 — No indicator for the currently *selected* node

**Status:** Open
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Minor, trivially fixable.

Clicking a node opens its detail panel but the node itself looks unchanged, so there is nothing
tying the panel to the box you clicked. `PipelineNode` destructures only `data`
([Pipeline.tsx:41](../../asct-fe-desktop/src/pages/Pipeline.tsx#L41)) and never reads React Flow's
`selected` prop, which it is already being handed.

### Fix

Read `selected` in `PipelineNode` and give it a ring/border treatment. (Distinct from the *running*
indicator — a node can be both.)

---

## ISSUE-9 — The approve gate doesn't say what you're approving

**Status:** Open
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Major — it asks for a decision while withholding what the decision is about.

### Symptom

> There was an approve gate and an approve button, but it didn't specify what I'm approving.

The banner shows the raw gate id (`after_sa`) and an **Approve** button
([Pipeline.tsx:230-238](../../asct-fe-desktop/src/pages/Pipeline.tsx#L230-L238)). The spec's
intent for gates is explicitly richer — section 9: *"At a gate the user may edit the artifact;
edits create a new version and mark downstream artifacts stale."* You cannot sensibly edit, or
even approve, an artifact you are not shown.

### Fix

Name the gate in words and show what was just produced: for `after_sa`, the architecture's style,
its components and contracts (all available from `GET /runs/{id}/artifacts/Architecture/{id}`);
for `after_ba`, the requirements and milestones. The `after_milestone` gate already does this
properly via `MilestoneGate`/`MilestoneRail` — the earlier gates should match that standard. Editing
the artifact at the gate remains unimplemented and is a separate, larger piece of work.

---

## Suggested fix order

ISSUE-4 first: without a trustworthy answer to "where is this run now?", none of the others can be
evaluated by looking at the screen. Then ISSUE-9 and ISSUE-8 (both small, both immediately
visible). Then ISSUE-6 and ISSUE-7 together — they are the same underlying work (publish finer
events from the engine, render them), and ISSUE-5 falls out of ISSUE-7 for free.
