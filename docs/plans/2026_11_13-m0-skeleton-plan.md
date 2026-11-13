# M0: Skeleton — Plan

Date: 2026-11-13
Status: **Done** (see `docs/PROGRESS.md` for the live status across all milestones)

## Goal (from the spec, section 10)

> Create the three repositories (`asct-app` as root, with `asct-be-engine` and `asct-fe-desktop` as
> submodules; layout in section 4), `uv` in the engine and `pnpm` in the UI, lint and type-check config, CI
> per repository, and a root script that runs both. FastAPI app with `/health`.
>
> Acceptance: `uv run pytest` and `pnpm build` pass on a fresh recursive clone of `asct-app`.

## What was done

1. **Repositories created and linked.**
   - `asct-app` (this repo) initialized at `c:\dev\asct-app`, remote `origin` set to
     `https://github.com/appsmith-ct/asct-app.git`.
   - `asct-be-engine` and `asct-fe-desktop` built in a scratch location, committed, and pushed to their
     (previously empty) GitHub repos, then wired into `asct-app` as git submodules via
     `git submodule add <url> <path>` (so each clones cleanly from GitHub rather than being nested by hand).
   - `gh auth setup-git` was required once to let `git push` use the already-authenticated `gh` credentials
     (the Windows Git Credential Manager had a stale token without `workflow` scope, which GitHub rejects
     when a push includes a `.github/workflows/*.yml` file).

2. **Engine (`asct-be-engine`): uv-managed Python 3.12 project.**
   - `pyproject.toml` with `fastapi`, `uvicorn` as runtime deps; `pytest`, `pytest-asyncio`, `httpx`, `ruff`,
     `mypy` as a dev dependency group.
   - `ruff` configured (line length 100, `E/F/I/UP/B` rules); `mypy --strict` on `appsmith/`.
   - Package layout from spec section 4 scaffolded as empty packages with a one-line docstring noting which
     milestone fills them in: `api/` (has the real `/health` endpoint), `core/`, `artifacts/`, `context/`,
     `roles/`, `graphs/`, `tools/`, `deploy/`, `defaults/`, `eval/`.
   - `GET /health` returns `{"status": "ok"}`, covered by one `pytest` test using `TestClient`.
   - `.github/workflows/ci.yml` runs `uv sync`, `ruff check`, `mypy`, `pytest` on push/PR to `main`.
   - Verified locally: `uv run pytest`, `uv run ruff check .`, `uv run mypy appsmith` all pass.

3. **UI (`asct-fe-desktop`): pnpm-managed Vite + React + TypeScript project.**
   - Scaffolded with `pnpm create vite@latest . --template react-ts` (current create-vite ships `oxlint`
     for linting instead of ESLint — kept as-is rather than swapping in an unrequested toolchain).
   - `src-tauri/` added as a placeholder directory with a README noting the Tauri v2 shell lands in M8, so
     the repo layout matches spec section 4 ahead of time without building Tauri integration early.
   - `.github/workflows/ci.yml` runs `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm build` on
     push/PR to `main`.
   - Verified locally: `pnpm build` and `pnpm lint` both pass.
   - Tailwind and React Flow (section 3's UI stack) are deliberately **not** added yet — they arrive with
     the actual screens in M6, per the spec's milestone sequencing.

4. **Root repo (`asct-app`).**
   - `docs/` holds this plan, the spec, the original spec-gen instructions, the GitHub links doc, and the
     live `PROGRESS.md` status tracker (new documents going forward are named `YYYY_MM_DD-<slug>.md`).
   - `scripts/dev.sh` and `scripts/dev.ps1`: run the engine (`uv run uvicorn ...`) and the UI (`pnpm dev`)
     together for local development.
   - `scripts/setup.sh` and `scripts/setup.ps1`: run `uv sync` in the engine and `pnpm install` in the UI,
     for a fresh clone.
   - Root `CLAUDE.md` and `README.md` describing the three-repo layout, clone instructions
     (`git clone --recurse-submodules`), and a pointer to `docs/PROGRESS.md`.

## Acceptance check

- [x] `uv run pytest` passes in `asct-be-engine` (1 test, `GET /health`).
- [x] `pnpm build` passes in `asct-fe-desktop`.
- [x] Both verified against a **fresh recursive clone** of `asct-app` from GitHub, not just the local
      working copy that produced the commits (see `docs/PROGRESS.md` for the verification run).

## Notes / deviations

- The spec's section 4 layout lists `src-tauri/` and the full `appsmith/` package set; M0 scaffolds all of
  it as directories/placeholders but only implements what M0 actually requires (the `/health` endpoint and
  CI). Everything else is an empty package with a docstring pointing at the milestone that fills it in, so
  future sessions (or future Claude Code runs) don't mistake an empty directory for an oversight.
- No Alembic/SQLite/LangGraph yet — those start in M1.
