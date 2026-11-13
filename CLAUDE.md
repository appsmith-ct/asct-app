# CLAUDE.md — asct-app (root)

Appsmith-CT simulates a software company (BA, Software Architect, Tech Leads, Developers, QA) as a
LangGraph pipeline over small, self-hosted LLMs, to see how far small models can carry the whole software
delivery process when complexity is pushed into decomposition, information hiding, and tool-based
verification instead of model capability.

**Before doing anything else in this repo, read `docs/PROGRESS.md`** — it records which milestone is
active and what's done vs. remaining, and survives context compaction even when this conversation doesn't.
The full build spec is `docs/specs/2026_11_13-appsmith_ct_implementation_specification.md`; build strictly
in the milestone order in its section 10, and keep the FakeLLM test suite green at every step (no milestone
needs a GPU to pass CI).

## Repository layout

```
asct-app/                root repo — docs, scripts, submodule pointers only, no application code
  docs/                  spec, plans (dated), progress tracker, API schemas once exported
  scripts/               setup and dev helpers that span both submodules
  asct-be-engine/        submodule: Python engine (FastAPI + LangGraph)
  asct-fe-desktop/       submodule: React UI + Tauri shell
```

`asct-be-engine` and `asct-fe-desktop` are independent repositories with their own `CLAUDE.md`, CI, and
history — read the relevant one before working inside it. The only coupling between them is the engine's
API: the engine exports its OpenAPI document and event schema to `docs/api/`, and the UI generates its
TypeScript client from that export, never from hand-guessed shapes.

## Working in this repo

- Clone with `git clone --recurse-submodules` (or `git submodule update --init --recursive` after a plain
  clone). A submodule is checked out at whatever commit the root repo's index points to — after changing a
  submodule, commit the pointer update in the root repo as its own commit, separate from the submodule's
  own commit.
- Documents land in `docs/`, dated `YYYY_MM_DD-<slug>.md` (matching `docs/specs/` and `docs/plans/`
  already there) — this is a project convention, so date new plans/specs the same way rather than
  overwriting prior dated files.
- `scripts/setup.ps1` / `setup.sh` install dependencies in both submodules; `scripts/dev.ps1` / `dev.sh`
  run the engine and the UI together for local development.
- This repo holds no application code of its own — if you're about to write engine or UI code outside
  `docs/` or `scripts/`, you're almost certainly in the wrong repo; `cd` into the submodule instead.
