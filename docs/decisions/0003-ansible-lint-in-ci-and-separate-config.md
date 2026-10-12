# ADR 0003: Run ansible-lint in CI and a separate pre-commit config, not as a local git hook

**Status:** Accepted
**Date:** 2026-10-12

## Context

`ansible-lint` was configured in `../../.pre-commit-config.yaml`, the config that
`pre-commit install` turns into the local git hook. Two problems showed up:

1. **It breaks `git commit` on native Windows.** `ansible-lint` refuses to
   install there (its maintainers support Linux, macOS and WSL only), and
   pre-commit builds the environment of *every* configured hook, even when
   no matching file is staged. So on Windows every commit failed unless
   `SKIP=ansible-lint` was set by hand each time.
2. **The hook linted far more than the Ansible code.** The upstream hook is
   defined with `pass_filenames: false` and `always_run: true`, so the
   `files: ^ansible/` filter in our config was ignored and `ansible-lint`
   scanned the whole repository. In CI it reported style violations in
   `../../docker-compose/docker-compose.yml`, which has nothing to do with Ansible.

Development happens on Windows and macOS (and will use Linux in CI and
later for Terraform/Ansible work), so the setup has to behave the same
everywhere.

## Options considered

- **A. Separate pre-commit config, run in CI and by hand.** Move the
  `ansible-lint` hook to `../../.pre-commit-config-ansible.yaml`, which
  `pre-commit install` does not use. CI runs both configs; on
  Linux/macOS/WSL it can be run locally (`make lint-ansible`).
- **B. Move all local development to WSL2.** Fixes the problem and removes
  other Windows friction (bash scripts, Docker networking, later
  Terraform/Ansible tooling), but it is a change of working environment
  for one hook, and it would not help anyone who commits from native
  Windows or any other setup that cannot run `ansible-lint`.
- **C. No local git hook at all; run pre-commit in CI only.** Simple, but
  it gives up fast local feedback for every other linter (shellcheck,
  sqlfluff, ruff, YAML checks, private-key detection) to solve a problem
  that concerns one of them.

## Decision

Option A. The `ansible-lint` hook lives in `../../.pre-commit-config-ansible.yaml`
and is pointed at `ansible/` explicitly (`args: ["ansible/"]`) so it lints
only the Ansible tree. `.github/workflows/lint.yml` runs both configs, so
Ansible files are still linted before anything is merged. `git commit`
never installs or runs `ansible-lint`, on any OS, and no `SKIP` workaround
is needed.

WSL2 (option B) stays *recommended* for Windows contributors, because it
makes `ansible-lint` runnable locally and brings the shell closer to the
containers, but it is not required for the commit workflow to work.

## Consequences

- `git commit` works on native Windows, macOS and Linux with identical
  behaviour; the `SKIP=ansible-lint` instruction is removed from
  `../../CONTRIBUTING.md`.
- **CI is the gate for Ansible code.** A contributor on native Windows
  learns about `ansible-lint` findings from CI, not from the commit. On
  Linux/macOS/WSL, run `make lint-ansible` before pushing once the roles
  have real content.
- Two pre-commit configs must be kept consistent. The `ansible-lint`
  version is pinned in two places (`../../.pre-commit-config-ansible.yaml` and
  `requirements-ansible.txt`) and should be bumped together.
- The repository currently has only README files under `../../ansible`, so the
  hook has little to check until the Ansible roles are written (ROADMAP
  Iteration 7). Because the scope is now explicit, it will not report
  non-Ansible YAML in the meantime.
- If development later moves entirely to Linux/WSL2, the hook can be folded
  back into the main config; this ADR should then be superseded.
