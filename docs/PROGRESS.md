# Appsmith-CT — Build Progress

This is a living status tracker, updated as work happens, so progress survives context compaction across
Claude Code sessions. For what each milestone requires, see
`docs/specs/2026_11_13-appsmith_ct_implementation_specification.md`, section 10. For how a specific
milestone was executed, see the matching dated plan in `docs/plans/`.

Last updated: 2026-11-13

## Milestone status

| Milestone | Status | Plan doc |
| --- | --- | --- |
| M0: Skeleton | **Done** | `docs/plans/2026_11_13-m0-skeleton-plan.md` |
| M1: Engine foundation | Not started | — |
| M2: Intake and BA | Not started | — |
| M3: Software Architect | Not started | — |
| M4: Component subgraph | Not started | — |
| M5: Integration, staging and QA | Not started | — |
| M6: API and UI | Not started | — |
| M7: Milestone loop and change requests | Not started | — |
| M8: Packaging and evaluation | Not started | — |

## M0 — detail

**Done 2026-11-13.** Three repos created and linked (`asct-app` root, `asct-be-engine` and
`asct-fe-desktop` as submodules, each pushed to the GitHub repos listed in `docs/github_links.md`). Engine
has a `uv`-managed FastAPI app with `GET /health` and a passing `pytest`/`ruff`/`mypy` setup; UI has a
`pnpm`-managed Vite/React/TypeScript scaffold with passing `pnpm build`/`pnpm lint`. CI workflows exist in
both component repos. Root `CLAUDE.md`/`README.md` and `scripts/dev.*`/`scripts/setup.*` are in place.

Full detail, including the one credential-setup snag (`gh auth setup-git`) and the deliberate
not-yet-built pieces (Tailwind, React Flow, Alembic, LangGraph — all scheduled for later milestones): see
`docs/plans/2026_11_13-m0-skeleton-plan.md`.

**Acceptance verification:** done. A fresh `git clone --recurse-submodules` of `asct-app` from GitHub into
a scratch directory, then `uv run pytest` in `asct-be-engine` and `pnpm install && pnpm build` in
`asct-fe-desktop`, both pass. M0 is fully closed out.

## Working agreements for future sessions

- Confirm the active milestone against this file before writing code; don't build ahead of the current
  milestone (e.g. no LangGraph graphs before M2, no tool-jail before M4) even if it looks convenient — the
  spec sequences milestones so each is independently demonstrable.
- When a milestone finishes, add a dated plan doc under `docs/plans/` (`YYYY_MM_DD-m<n>-<slug>-plan.md`)
  and update the table and "Last updated" date above before ending the session.
- If a milestone is left partially done, record exactly what's done vs. remaining under that milestone's
  row here, not just in conversation — a new session should be able to pick up from this file alone.
