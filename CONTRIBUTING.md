# Contributing Guide

This project follows **Git Flow**. This document describes the branching
model, naming conventions, and PR process used throughout the project.

## Branching Model

| Branch | Purpose | Branches from | Merges into |
|--------|---------|---------------|-------------|
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

> **Line endings:** this repository enforces LF line endings via
> `.gitattributes` (shell scripts in particular must stay LF — they run
> inside Linux containers, and a CRLF-mangled script fails at container
> startup with `/bin/bash^M: bad interpreter`). As a second line of
> defense, also set this locally, especially on Windows:
> ```bash
> git config core.autocrlf input
> ```

Linters run automatically in CI (`.github/workflows/lint.yml`), but running
them locally before pushing catches issues sooner. This project is
developed across multiple OSes (Windows and macOS at different times) —
the setup below is written to behave the same everywhere, with
platform-specific notes called out explicitly rather than assumed.

Set up a virtual environment pinned to the same tool versions used in CI:

```bash
python3 -m venv .venv
source .venv/bin/activate       # .venv\Scripts\activate on Windows (PowerShell/cmd)
pip install -r requirements.txt
pre-commit install              # runs the hooks automatically on every commit
```

`ansible-lint` is deliberately **not** part of `.pre-commit-config.yaml`
(the config `pre-commit install` uses as the local git hook) — it lives
in a separate `.pre-commit-config-ansible.yaml`. This means `git commit`
never tries to install or run it, on any OS, and never fails because of
it. It's run explicitly instead:

```bash
pip install -r requirements-ansible.txt
pre-commit run --all-files -c .pre-commit-config-ansible.yaml
```

> **Why a separate config, not just a Windows workaround:** `ansible-lint`
> refuses to install on native Windows entirely (its maintainers require
> Linux/macOS/WSL). It installs and runs fine on macOS/Linux with no
> special handling — but pre-commit provisions *every* configured hook's
> environment eagerly on first run, even for files nothing in the current
> commit touches. Keeping it in the main config would mean every commit
> on Windows fails outright, which is worse than "run it separately."
> Splitting it out gives identical local behavior on every OS: the git
> hook never touches Ansible, and `.github/workflows/lint.yml` runs both
> configs in CI regardless of what OS the change was authored on.

> **Windows-only note:** since this project also uses Docker Compose and
> later Terraform/Ansible more heavily, developing inside **WSL2** is
> recommended (`wsl --install -d Ubuntu-24.04`) for a Linux-like shell —
> but it is not required for the above to work; `ansible-lint` just won't
> run locally on native Windows regardless (CI still catches it).

> **`make` availability:** the Makefile targets need a POSIX-ish shell
> and GNU Make. macOS and Linux have `make` available out of the box (or
> via `xcode-select --install` / your package manager). On native
> Windows, use WSL2, Git Bash, or `choco install make`.

To run everything manually against the whole repo:

```bash
pre-commit run --all-files                                  # main config
pre-commit run --all-files -c .pre-commit-config-ansible.yaml  # Linux/WSL only
```

To run a single hook only (useful when iterating on one file type):

```bash
pre-commit run sqlfluff-lint --all-files
pre-commit run ansible-lint --all-files -c .pre-commit-config-ansible.yaml
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

`requirements.txt` pins cross-platform tooling (pre-commit, sqlfluff,
ruff). `requirements-ansible.txt` pins `ansible-lint`/`ansible-core`
separately (see the note above on why). Runtime dependencies for the ETL
scripts live in `requirements.txt`, introduced in Iteration 2 once
`scripts/etl/` has actual code.

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
