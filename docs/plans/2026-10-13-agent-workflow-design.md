# Agent Workflow Design

Rydah will keep its delivery workflow in a repository-level `AGENTS.md` so new
Codex threads inherit it automatically. Work starts from `develop` on a focused
feature branch. Planning, implementation, and review use different agents only
when the work is substantial enough to benefit from delegation.

Planning uses `gpt-6-astra` at high reasoning effort for changes that cross
mobile, Worker, database, or release boundaries. Implementation uses
`gpt-6.1-sol` at high reasoning effort. Review uses `gpt-6.1-sol` at medium
reasoning effort after implementation, with a focus on affected files, tests,
and release risks. Small, isolated fixes remain in the primary thread to avoid
the cost and latency of delegation.

Each feature is tested, committed, pushed, and proposed to `develop`. Releases
are promoted from `develop` to `main` through a pull request after validation.
