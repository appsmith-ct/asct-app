# Pipeline screen UX issues — recorded 2026-11-20

Found by using the Pipeline screen against a real model after the post-M6 fixes landed. Intake now
completes reliably; everything *after* intake is where the UX falls apart.

These are one cluster, not six unrelated bugs. The Pipeline screen was built in M6 against a
FakeLLM engine where every node finishes in milliseconds, so "what is happening right now" never
had to be answered — the run was over before you could look. Against a real model a single node
takes minutes, the page gets refreshed mid-run, and the screen has nothing to say.

Status key: **Open** = not started, **Fixed** = done and verified.

**Two reports in this document were withdrawn after investigation** (ISSUE-4's Cause C, and
ISSUE-13). Both turned out to be artifacts of headless Chromium under Playwright rather than
defects in the app. They are kept rather than deleted so the misleading screenshots and logs in
`asct-test-projects/` aren't mistaken for evidence later. The lesson for anyone extending this
investigation: **confirm a UI symptom in a real browser before writing it up** — headless
automation produced two convincing phantoms here.

---

## ISSUE-4 — Run progress is invisible, and a refresh loses it entirely

**Status:** **Fixed** 2026-11-21 (causes A and B; C was withdrawn)
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`, `src/api/useRunEvents.ts`; engine events WS
**Severity:** Blocker for actually watching a run — this is the screen's whole job.

### Symptom

> I cannot initiate the pipeline run. The run button has disappeared from the pipeline page. First
> there was nothing in the pipeline page, after a few refreshes I saw that a single BA turn has
> run. I think the engine is running in the background but the FE is not properly showing them.

Two distinct things, which is why it reads as confusing rather than simply broken. Both were
reproduced; the measurements below are from a real run against the real model. (A third —
"the canvas paints nothing at all" — was reported and then withdrawn; see Cause C.)

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

### Cause C — WITHDRAWN: "the canvas paints nothing at all"

**Withdrawn 2026-11-21.** I reported that the React Flow canvas rendered completely blank — from
arrival, through a reload, and still blank four minutes later at the gate — based on screenshots
and DOM measurements from my automation (`shots-pipeline-just-started.png`,
`shots-gate-reached.png`, where five nodes sat in the DOM at correct geometry with empty
`innerText` and nothing painted).

**A screenshot from the user's own browser, at that same gate, shows the graph rendering
perfectly**: all five nodes visible and labelled, Business Analyst and Software Architect with
green completion ticks, the remaining three with idle markers, and the node detail panel correctly
populated after clicking Software Architect.

So this was an artifact of **headless Chromium under Playwright**, not of the app — the second
time in this investigation that my harness produced a phantom bug (see the withdrawn ISSUE-13).
In headless runs it was intermittent: a direct page load rendered, a client-side navigation
sometimes did not. In a real browser it simply works.

Nothing here needs fixing. Kept as a withdrawn note so the blank-canvas screenshots in
`asct-test-projects/shots/` aren't mistaken for evidence of a product defect.

### Fix

1. The engine should be able to answer "where is this run now?" over REST, not only as a live
   stream — `GET /runs/{id}` already returns `status`/`next_gate`; it should also return the
   per-node state the UI is trying to reconstruct. Deriving it from stored artifacts (as
   `GET /runs/{id}/milestones` already does) makes it survive an engine restart too.
2. Failing that, at minimum: a `running` case in `resolvedStatus` that marks the first
   not-yet-finished node as running, and a replay of recent events when the events WS connects.
3. Say plainly that a run is in progress, where the Start button used to be — not in subtitle
   grey. Offer the Start button whenever there is genuinely no active run.

### What was done

All three. `RunHandle` accumulates per-node state by subscribing to the run's own event bus, so
anything that publishes a `NodeStarted` is visible to `GET /runs/{id}` for free, with no second
reporting path to keep in sync; `EventBus` also keeps a bounded replay backlog that the events WS
replays on connect, so a late subscriber's event *log* is honest too. The screen reads node state
from REST and layers the live feed over it for freshness, and the header says
"Running Business Analyst · 3m 20s" with a ticking counter — the part that tells slow apart from
stuck — plus a Stop button (ISSUE-12).

Not covered: a run whose engine restarted mid-flight. `RunManager` is in-memory by design, so
`GET /runs/{id}` 404s and the screen offers Start, which resumes from the checkpoint. Deriving
node state from stored artifacts (fix option 1's second half) would make even that case
answerable, and is still worth doing.

---

## ISSUE-5 — Clicking "Build milestone" shows the intake conversation's LLM calls

**Status:** **Fixed** 2026-11-21
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Minor, but actively misleading — it attributes work to the wrong node.

### Confirmed against a real run

Clicking "Build milestone" on `todo-app-2` would list exactly this and nothing else:

```
intake_turn (role=intake)
intake_turn (role=intake)
intake_turn (role=intake)
```

— the three intake conversation turns, attributed to the component build.

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

### What was done

`BUILD_MILESTONE_NODES` in `Pipeline.tsx`, matched against the part of the call's node name before
the first `:` (the engine qualifies a call with its task, role, attempt and review round, and the
agent loop appends `:step<n>` on top of that). Confirmed against a real `--fake-llm` run: clicking
"Build milestone" mid-build lists `tl_plan (role=tech_lead)` and nothing from intake.

---

## ISSUE-6 — No indication of what is running, or whether anything is happening at all

**Status:** **Fixed** 2026-11-21
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

### What was done

Exactly that. `LLMClient` gained `stream_events`: an API run streams every call and publishes each
chunk as an `llm_delta` event carrying the node and role it belongs to. `generate_structured` has
taken an `on_delta` since post-M6 — the run path simply never passed one — so this is the Chat
screen's proven mechanism, not a new one. Deltas are kept out of the event backlog (they describe
a moment, not a state) and the client caps what it keeps, since reasoning runs to 3k-30k
characters per call.

The Pipeline screen renders them through `LiveTurn`, unchanged, and the header names the running
step with a ticking elapsed counter (ISSUE-4).

Verified against the real model, which is the only way to see this work: a scripted fake answers
in one chunk and finishes in milliseconds, so it can show that delta frames exist but not that
text keeps arriving through a minutes-long call.
`scripts/manual_run_events_check.py` is that check, kept so it can be re-run.

---

## ISSUE-7 — "Build milestone" is a whole graph shown as one box

**Status:** **Fixed** 2026-11-21
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

### What was done

The project graph's five nodes can be wrapped from outside because they are LangGraph nodes
assembled in one place. The milestone flow cannot: it is plain Python driving a per-component
subgraph, with loops and bounded retries an outer wrapper cannot see into. So its steps report
themselves through a `StepObserver` threaded down from the API layer
(`appsmith/core/step_observer.py`), defaulting to a no-op everywhere so the CLI and the existing
tests are untouched. Events carry `parent="build_milestone"` and `component_id`, because the same
step names repeat per component.

Reported per *task* as well as per `process_tasks`: that loop is the long part of a build (a dev
attempt, its gates, a review, maybe an escalation up the rung ladder), so one spinner over the lot
would sit still for most of the run.

The screen draws `build_milestone` with an expand toggle, opening into one row per component
(Tech Lead plan → scaffold → tasks → component E2E → handoff) and a row for the milestone-level
steps (integrate → stage → QA → triage). The static shape comes from `GET /runs/{id}/milestones`,
so the subgraph is visible before the run reaches it.

Two rendering bugs surfaced while verifying it, both now fixed: React Flow leaves a node
`visibility: hidden` until it has measured it and re-measures rebuilt nodes, so recreating the
`nodes` array on every render (a 3s poll makes that often) left the graph invisible in beats —
which is also the most likely mechanism behind the withdrawn blank-canvas observation in ISSUE-4's
Cause C, since it would show up far more readily under headless automation than in a browser being
watched by a human. And the view now re-fits when the node count changes, not only when the pane
resizes, because expanding the subgraph grows the graph without resizing anything.

Not covered: `GET /runs/{id}/llm-calls` unions the per-component call traces without saying which
component each came from, so with two components the Tech Lead plans for both appear under either
one's `tl_plan` in the detail panel. Fixing that is a change to the call-tracing shape, not to the
screen.

---

## ISSUE-8 — No indicator for the currently *selected* node

**Status:** **Fixed** 2026-11-21
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Minor, trivially fixable.

Clicking a node opens its detail panel but the node itself looks unchanged, so there is nothing
tying the panel to the box you clicked.

Confirmed from the user's own browser at the `after_sa` gate: the Software Architect node had been
clicked — the right-hand panel is headed "Software Architect" and lists its `sa` call — yet that
node is drawn identically to Business Analyst beside it. The only clue as to which node the panel
belongs to is the panel's own title. `PipelineNode` destructures only `data`
([Pipeline.tsx:41](../../asct-fe-desktop/src/pages/Pipeline.tsx#L41)) and never reads React Flow's
`selected` prop, which it is already being handed.

### Fix

Read `selected` in `PipelineNode` and give it a ring/border treatment. (Distinct from the *running*
indicator — a node can be both.)

### What was done

Exactly that: a primary-coloured border and ring, with `selected` set on the node list the
Pipeline screen builds, so it survives that list being rebuilt on every render.

---

## ISSUE-9 — The approve gate doesn't say what you're approving

**Status:** **Fixed** 2026-11-21 (gate artifact *editing* remains unimplemented, as noted below)
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Major — it asks for a decision while withholding what the decision is about.

### Symptom

> There was an approve gate and an approve button, but it didn't specify what I'm approving.

Confirmed verbatim from a real run — the banner's entire text content is:

```
Paused at gate after_sa
Approve
```

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

### What was done

A new `GateBanner` component: the gate named in words ("Approve the architecture"), what approving
it sets off, the architecture's style/deployment/components/contracts/decision log, the BA's plan
beside it, and "Approve and continue". The raw gate id stays as a quiet hint — it is what the
engine logs and what `POST /runs/{id}/control` talks about — it just isn't the message any more.
Editing at the gate is still unimplemented, as noted above.

---

## ISSUE-10 — The node detail panel never refreshes during a run

**Status:** **Fixed** 2026-11-21
**Area:** `asct-fe-desktop/src/pages/Pipeline.tsx`
**Severity:** Major — found while tracing the above, not reported; it compounds ISSUE-4.

### Cause

[Pipeline.tsx:109-114](../../asct-fe-desktop/src/pages/Pipeline.tsx#L109-L114) fetches
`GET /runs/{id}/llm-calls` in an effect keyed on `[projectId, runStatus?.status]`. The *status
string* is the dependency, not the status object — and for the entire duration of a run that
string is `"running"` and never changes. So the call list is fetched once, when the screen mounts,
and then not again until the run transitions to `paused_at_gate`, `done` or `failed`.

Clicking any node mid-run therefore shows whatever was true at mount — in practice an empty list,
because at mount the run has usually made no calls yet. Combined with ISSUE-4 (nodes stuck at
`idle`), the screen has two independent reasons to look like nothing is happening.

The status *object* is rebuilt every 3s by the polling effect above it, so depending on
`runStatus` rather than `runStatus?.status` would refetch every 3s — which is the intent, and
presumably what was meant. That's a one-word fix, but the call list is probably the wrong thing
to poll for live progress anyway (see ISSUE-6).

### What was done

Its own `refreshCalls`, on the same 3s tick, and only while a node is selected (plus immediately
on clicking one, since a panel that takes three seconds to show what it already has reads as
empty). Deliberately *not* folded into the status poll: this response carries every call's full
prompt and response, so anything awaiting the status refresh — approving a gate, submitting a
change request — would then be waiting on the heaviest fetch the screen makes. Doing exactly that
briefly left the change-request box holding submitted text for seconds, caught by the smoke test.

---

## ISSUE-11 — A model call has no timeout, so a stalled request hangs the run forever

**Status:** **Fixed** 2026-11-21
**Area:** `asct-be-engine` — `appsmith/api/deps.py`, `appsmith/cli.py` (chat-model factories)
**Severity:** Major — turns "the model is slow" into "the run is dead", with no way to tell.

### Symptom

No observed hang — the apparent 8-minute stall that first prompted this entry turned out to be a
broken test harness (see the withdrawn ISSUE-13), and the chat path has since been watched
streaming correctly end to end. **This entry stands on the code, not on an incident:** the absence
of a timeout is verified directly, and it is a latent hang waiting for the first dropped
connection.

### Cause

Nothing sets a request timeout anywhere:

```
request_timeout attr : None
openai client timeout: None
```

`ReasoningChatOpenAI` is constructed without `request_timeout`, langchain passes that `None`
straight to the openai SDK, and the SDK passes it to httpx — where `None` means *disable the
timeout*, not *use a default*. A connection that stalls or is silently dropped would block the
calling thread indefinitely. For a run, that means the node never finishes, no event is ever
published, and the Pipeline screen (already saying nothing, per ISSUE-4) keeps saying nothing
forever.

It also compounds ISSUE-12: a `stop` control cannot interrupt a call that cannot time out, so
"stop" could never be responsive while this stands.

### Fix

Give the profile a timeout (a `ModelProfile` field, like `max_tokens`) and pass it through both
chat-model factories. It has to be generous — a legitimate thinking pass genuinely takes minutes —
but finite, so a stall surfaces as a failed node that can be retried rather than a silent hang.
Worth pairing with a heartbeat on the events WS so "still waiting, 240s elapsed" is distinguishable
from "nothing is happening".

### What was done

`ModelProfile.request_timeout`, stored (with its own migration), editable via
`appsmith config set-profile --request-timeout`, and passed through both chat-model factories —
the API's and the CLI's, which have drifted before, so there is a test on each. The shipped default
is 600s, and the migration **backfills** it onto profiles that already exist rather than leaving
them NULL: no profile ever chose "no timeout", they simply predate the setting, so leaving them
alone would ship the fix to new installs and skip every machine that has already hit the problem.
(Caught by running the real-model check against a copy of this machine's own settings database,
which reported `timeout : None per call` after the migration.)

The "still waiting, Ns elapsed" half is now the Pipeline screen's ticking elapsed counter
(ISSUE-4), which answers the same question without a heartbeat frame.

---

## ISSUE-12 — A run cannot be stopped, paused, or cancelled

**Status:** **Fixed** 2026-11-21 (`stop` is real; `pause`/`resume`/`retry_node`/`restart_from_node` are unimplemented and now say so with a 501)
**Area:** `asct-be-engine` — `appsmith/api/run_manager.py`, `appsmith/api/routers/runs.py`;
`asct-fe-desktop` Pipeline screen
**Severity:** Major — the only way out of a running build is to kill the engine process.

### Symptom

> The frontend and backend [are] still running from my run. I think it is still running my
> project's pipeline. There is no way for me to stop it.

Exactly right, and killing the engine is currently the only option.

### Cause

`RunControlRequest.action` declares the spec's full set — `pause`, `resume`, `stop`,
`retry_node`, `restart_from_node` ([schemas.py:74-82](../../asct-be-engine/appsmith/api/schemas.py#L74-L82))
— but the route implements two of them and rejects the rest with "not implemented yet"
([runs.py:121-128](../../asct-be-engine/appsmith/api/routers/runs.py#L121-L128)). The UI offers no
control for them either. So the API advertises a vocabulary it doesn't honour, which is worse than
not advertising it: a client can send `{"action": "stop"}`, get `200 OK` with `ok: false`, and
have nothing happen.

Underneath, a run executes on a `daemon=True` thread inside the engine process
(`RunManager.start_run`). There is no cancellation token, and the long block is a single
synchronous model call with **no timeout** (ISSUE-11) — so even a cooperative `stop` would not
interrupt the call in flight. Killing the process is genuinely the only thing that works today.

Nothing is lost by doing so: every graph is checkpointed, so a restarted engine resumes from the
last completed node. That is worth saying in the UI, because "kill the server" reads like
data loss and isn't.

### Fix

1. Implement `stop` as a cooperative cancellation flag the graph checks between nodes, plus a
   request timeout so an in-flight call can actually be abandoned (ISSUE-11 is a prerequisite for
   `stop` being responsive rather than "effective after up to N minutes").
2. Until then, make the API honest: reject unimplemented actions with `501`, not `200 ok:false`.
3. Give the Pipeline screen a Stop control, and tell the user plainly that stopping is safe
   because the run resumes from its checkpoint.

### What was done

All three. `CancellationToken` (`appsmith/core/cancellation.py`) is checked at the three boundaries
that bound how long a stop takes to land: between project-graph nodes, before each `LLMClient`
attempt, and between streamed chunks of a response — the last being what makes it feel immediate,
since a thinking pass is minutes of chunks. A run parked at a gate has no thread to interrupt and
stops outright. `RunCancelled` is deliberately not a subclass of the engine's failure types, so the
`except` clauses that turn bad model output into a graph failure cannot record a stop as a crash.

Everything still unimplemented answers 501 instead of `200 {"ok": false}`. The UI has a Stop
button, a "Stopping…" state while the stop lands, and "Resume from checkpoint" after it has.

Not covered: a stop during a long *non-model* step inside the milestone flow (a pytest run, a
container build) waits for that step to finish, because the check points are node boundaries and
model calls. ISSUE-7's work threads the same token further in.

---

## ISSUE-13 — WITHDRAWN: "an answer sent during a reconnect strands the conversation"

**Status:** **Withdrawn 2026-11-21** — not a real bug. Recorded rather than deleted so nobody
re-reports it from the same misreading.

I reported that sending an answer left the chat permanently stuck with a spinner that never
cleared, and blamed a race between `status` and `socketRef.current`. That was wrong, and the fault
was in my own test harness.

The chat input's **placeholder changes while a turn is in flight** —
`'Type your answer…'` becomes `'Waiting for a response…'` ([Chat.tsx](../../asct-fe-desktop/src/pages/Chat.tsx)).
My driver waited on `input[placeholder="Type your answer…"]`, which therefore matched *nothing*
during a turn: `document.querySelector(...)?.disabled === true` evaluated to `undefined === true`,
i.e. false, forever. Every "stranded" turn was that selector, not the app. (Compounded by passing
`{timeout}` as `waitForFunction`'s second *positional* argument, which is `arg`, not options — so
my explicit timeouts were silently ignored and page defaults applied, making the durations look
far worse than they were.)

An instrumented run settled it: one page, every WS frame logged, one answer sent — the socket sent
the answer, the engine streamed `reasoning_delta` frames back token by token within seconds, and
the input returned. The chat path works correctly, including the streaming the Chat screen was
built for.

**Worth keeping from it:** a `readyState` guard on `sendAnswer` is still a reasonable hardening
(there genuinely is no check today), but there is no evidence of it failing in practice, and it
should not be presented as a bug.

---

## Progress

**All nine live issues are fixed as of 2026-11-21** (ISSUE-4's Cause C and ISSUE-13 were withdrawn
rather than fixed). The order below was followed as suggested, ending with ISSUE-6 and ISSUE-7
together, which were one piece of work.

What each fix deliberately leaves undone is recorded in its own "What was done" section rather
than here, so a gap is read next to the thing it belongs to: run state not surviving an engine
restart (ISSUE-4), editing an artifact at a gate (ISSUE-9), `pause`/`resume`/`retry_node`/
`restart_from_node` (ISSUE-12), and per-component attribution of LLM calls (ISSUE-7).

### Verified against the real model

`scripts/manual_run_events_check.py` (engine repo) drives the real API the way the UI does and
prints what the run publishes. Against `Qwen3.6-35B-A3B` on the LAN endpoint:

```
[    0.1s] node_started       ba
[    6.6s] streaming ba (ba): 4 reasoning chars, 0 answer chars
[   31.6s] streaming ba (ba): 4150 reasoning chars, 0 answer chars
[   66.7s] streaming ba (ba): 9745 reasoning chars, 0 answer chars
[   84.7s] node_finished      ba success
[  181.8s] node_finished      sa success
[  181.9s] node_started       tl_plan in build_milestone [backend]
[  275.6s] node_finished      tl_plan success in build_milestone [backend]
[  282.5s] node_started       task:T1 in build_milestone [backend]
```

That is the whole cluster's premise and its fix in one trace: steps that take 85, 97 and 94
seconds each — which is why a screen with nothing to say about them read as dead — and text
arriving throughout at roughly 800 characters per five seconds, which is what the screen now
shows. The milestone flow's own steps carry their parent and component, which is what
`build_milestone` expands into.

`GET /runs/{id}` answered the same question mid-build, which is ISSUE-4's actual fix — this is a
snapshot taken while the run was still going, and it is exactly what the screen draws:

```
ba                       success
sa                       success
build_milestone          running
tl_plan                  success in build_milestone [backend]
scaffold                 success in build_milestone [backend]
process_tasks            running in build_milestone [backend]
task:T1                  running in build_milestone [backend]
```

Reasoning volume per call, for the record: BA 21,340 characters, SA 23,048, `tl_plan` 23,260 —
the high end of the 3k-30k range the post-M6 notes flagged as the dominant cost. The `developer`
role has thinking off, so its agent-loop steps stream answer text only.

The FakeLLM suite cannot establish any of this by construction: a scripted fake answers in one
chunk and finishes in milliseconds. It establishes the shape (the frames exist, the steps are
reported, the UI renders them); only a real model establishes that they keep arriving.

## Suggested fix order

ISSUE-4 and ISSUE-10 first, together: they are the two reasons the screen looks dead during a
run, and without a trustworthy answer to "where is this run now?" none of the others can be
evaluated by looking at the screen. Then ISSUE-9 and ISSUE-8 (both small, both immediately
visible), and ISSUE-12's honesty fix (a one-line status code) alongside them. Then ISSUE-11 and
ISSUE-12's real `stop`, which are the same work. Then ISSUE-6 and ISSUE-7 together — they are the same underlying work (publish finer
events from the engine, render them), and ISSUE-5 falls out of ISSUE-7 for free.
