# Codex workflow for Rydah

## Branches and delivery

- Start each nontrivial feature from an up-to-date `develop`: fetch `origin`, switch to `develop`, and pull with `--ff-only`. Preserve unrelated local work; use an isolated worktree when needed.
- Create a focused `feature/<short-name>` branch before making changes. Keep each branch scoped to one feature or fix.
- Validate the affected code, commit coherent changes, push the feature branch, and open a pull request targeting `develop`. Include the behavior change and validation results in the PR.
- Release through a validated pull request from `develop` to `main`. Run the applicable tests and build checks before promotion.

## Agent roles

For nontrivial or cross-cutting work, use these roles in order:

| Role | Model | Reasoning | Responsibility |
| --- | --- | --- | --- |
| Planner | `gpt-6-astra` | high | Inspect the affected mobile, Worker, storage, and release boundaries; produce a focused plan with validation steps before implementation. |
| Implementer | `gpt-6.1-sol` | high | Implement the agreed plan and run the relevant checks. |
| Reviewer | `gpt-6.1-sol` | medium | Review the finished diff, test evidence, correctness, and release risks. |

- Use a planning subagent first and an implementation agent second for nontrivial or cross-cutting work.
- After implementation, use a reviewer for changes involving sharing, GPS, Cloudflare Workers, storage, or releases. Address actionable findings and rerun affected checks before opening the PR.
- Keep small, isolated fixes in the primary thread to save tokens. Delegate only when the scope or required review benefits from it.
- When spawning agents with explicit model assignments, use `fork_turns="none"` and provide the task, plan, paths, and necessary context explicitly.

## Validation

- Flutter changes: run `flutter analyze` and the relevant `flutter test` tests from `mobile/`; run the full suite when shared behavior changes.
- Worker changes: run `npm test` and `npm run typecheck` from `backend/`.
- Cross-cutting changes: run both sets of checks. For Android build or release changes, also run `flutter build apk --debug` or the applicable release build.
- Run `git diff --check` before committing. Report commands and results honestly; resolve failures before claiming completion or describe any checks that could not run.
