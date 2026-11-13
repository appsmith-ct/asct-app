# Appsmith-CT

A local, cross-platform desktop application that turns a chat with you into working software by running a
simulated software company — a Business Analyst, a Software Architect, Tech Leads, Developers and QA, each
played by a small self-hosted LLM inside a [LangGraph](https://github.com/langchain-ai/langgraph) pipeline.

It targets [PrismML Bonsai](https://prismml.com/) and runs entirely on local models, with no cloud
dependency. The experiment: can small, self-hosted LLMs carry an entire software delivery process — from a
chat about an idea to requirements, architecture, code, tests and a QA pass — when a company's own division
of labor (information hiding between roles, deterministic tools as the judge, bounded escalation) does the
work that model capability would otherwise have to?

See `docs/specs/2026_11_13-appsmith_ct_implementation_specification.md` for the full design and build plan,
and `docs/PROGRESS.md` for current build status.

## Repositories

This is the root repository. The application code lives in two submodules:

- [`asct-be-engine`](https://github.com/appsmith-ct/asct-be-engine) — the Python engine (FastAPI +
  LangGraph), the only part of the system that talks to models or the project workspace.
- [`asct-fe-desktop`](https://github.com/appsmith-ct/asct-fe-desktop) — the React UI, eventually packaged
  with Tauri v2; purely an observer/controller of engine runs.

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/appsmith-ct/asct-app.git
```

(Already cloned without them? `git submodule update --init --recursive`.)

## Quick start

```bash
# install dependencies in both submodules
./scripts/setup.sh      # or scripts\setup.ps1 on Windows

# run the engine and the UI together
./scripts/dev.sh        # or scripts\dev.ps1 on Windows
```

Until packaging (M8), the product runs as a local web app: the engine serves an API on `localhost`, and the
UI is a browser app pointed at it.

## Status

Building milestone by milestone — see `docs/PROGRESS.md` for what's done and what's next.
