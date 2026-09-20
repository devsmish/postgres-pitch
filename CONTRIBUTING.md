# Contributing Guide

This project follows **Git Flow**. This document describes the branching
model, naming conventions, and PR process used throughout the project.

## Branching Model

| Branch | Purpose | Branches from | Merges into |
|---|---|---|---|
| `main` | Always stable, deployable. Every commit on `main` is a tagged release. | — | — |
| `develop` | Main integration branch. All finished features land here first. | `main` (once, at project start) | — |
| `feature/*` | A single feature or task. | `develop` | `develop` |
| `release/x.y.z` | Stabilization before a release (docs, version bump, final testing, no new features). | `develop` | `main` **and** `develop` |
| `hotfix/x.y.z` | Urgent fix for a bug in production (`main`). | `main` | `main` **and** `develop` |

## Branch Naming

```
feature/<short-description>     e.g. feature/docker-compose-cluster
release/<version>               e.g. release/0.1.0
hotfix/<version>-<short-desc>   e.g. hotfix/0.1.1-replication-timeout
docs/<short-description>        e.g. docs/architecture-diagram
```

Use lowercase, hyphen-separated descriptions. Keep them short but specific
enough to understand the branch's purpose from its name alone.

## Commit Messages — Conventional Commits

```
<type>(<optional scope>): <short summary>

[optional longer body]
```

**Types used in this project:**

| Type | Use for |
|---|---|
| `feat` | A new feature or capability |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `ci` | CI/CD pipeline changes |
| `chore` | Maintenance, tooling, dependency bumps |
| `refactor` | Code change that neither fixes a bug nor adds a feature |

Examples:
```
feat(docker): add 3-node Patroni + etcd local cluster
fix(monitoring): correct replication lag query in grafana dashboard
docs: add disaster recovery runbook
```

Each commit should represent one logical change. Squash-merge feature
branches into `develop` so `develop`'s history stays readable.

## Local Development Setup

Linters run automatically in CI (`.github/workflows/lint.yml`), but running
them locally before pushing catches issues sooner. Set up a virtual
environment pinned to the same tool versions used in CI:

```bash
python3 -m venv .venv
source .venv/bin/activate       # .venv\Scripts\activate on Windows
pip install -r requirements-dev.txt
pre-commit install              # runs the hooks automatically on every commit
```

> **Windows users:** `ansible-lint` does not install on native Windows —
> its maintainers require Linux, macOS, or WSL (consistent with Ansible
> itself targeting Linux hosts). `../requirements-dev.txt` is Windows-safe
> and does **not** include it; `ansible-lint`/`ansible-core` live in
> `../requirements-linux.txt` instead.
>
> Since this project also uses Ansible, Docker Compose, and later
> Terraform, developing inside **WSL2** is recommended:
> ```powershell
> wsl --install -d Ubuntu-24.04
> ```
> Inside WSL, install both files:
> ```bash
> pip install -r requirements.txt -r requirements-linux.txt
> ```
>
> If you'd rather stay on native Windows for now, just install
> `../requirements-dev.txt` and rely on CI to catch Ansible issues; `pre-commit
> run --all-files` will still try to run `ansible-lint` via its own
> isolated environment and fail the same way, so skip it explicitly:
> ```powershell
> $env:SKIP="ansible-lint"; pre-commit run --all-files
> ```

To run everything manually against the whole repo:

```bash
pre-commit run --all-files
```

To run a single hook only (useful when iterating on one file type):

```bash
pre-commit run sqlfluff-lint --all-files
pre-commit run ansible-lint --all-files
pre-commit run ruff --all-files
```

Or call the tools directly, without going through pre-commit — matches
what CI runs, but gives more control (e.g. auto-fixing):

```bash
# SQL — lint, or auto-fix formatting issues
sqlfluff lint db/schema/*.sql
sqlfluff fix db/schema/*.sql

# Ansible — lint roles and playbooks
ansible-lint ansible/

# Python — lint, or auto-fix + format
ruff check scripts/
ruff check scripts/ --fix
ruff format scripts/
```

`../requirements-dev.txt` pins tooling only (pre-commit, sqlfluff, ansible-lint,
ruff). Runtime dependencies for the ETL scripts live in `requirements.txt`,
introduced in Iteration 2 once `scripts/etl/` has actual code.

## Workflow

### Starting a new feature

```bash
git checkout develop
git pull
git checkout -b feature/docker-compose-cluster
# ... work, commit ...
git push -u origin feature/docker-compose-cluster
# open a PR: feature/docker-compose-cluster → develop
```

### Preparing a release

```bash
git checkout develop
git pull
git checkout -b release/0.1.0
# bump version references, update CHANGELOG.md, final docs pass
# open a PR: release/0.1.0 → main
# after merge: tag the release on main
git checkout main
git pull
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
# merge main back into develop so develop has the release commit too
git checkout develop
git merge main
git push
```

### Hotfixing production

```bash
git checkout main
git pull
git checkout -b hotfix/0.1.1-replication-timeout
# ... fix, commit ...
# open a PR: hotfix/0.1.1-... → main
# after merge, tag v0.1.1, then also merge main back into develop
```

## Pull Requests

- Every change to `develop` or `main` goes through a PR — no direct pushes,
  even when working solo. This keeps a clean, reviewable history.
- Fill in the PR template (what changed, how it was verified, related
  ROADMAP item).
- Prefer small, focused PRs over large ones spanning multiple ROADMAP items.

## Definition of Done

A change is ready to merge into `develop` when:
- [ ] It works as described (manually verified locally)
- [ ] Relevant documentation is updated (README, ROADMAP, ADR if a design
      decision was made)
- [ ] Commit messages follow the convention above
- [ ] CI checks pass (once CI is in place — see ROADMAP.md, Iteration 11)

A `release/*` branch is ready to merge into `main` when everything above
holds for the full set of included changes, and the ROADMAP has been
updated to reflect the new state.
