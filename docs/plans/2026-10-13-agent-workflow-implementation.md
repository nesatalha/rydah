# Agent Workflow Implementation Plan

> **Status:** Implemented as the repository's `AGENTS.md`.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the Rydah multi-agent and Git workflow apply automatically to future Codex threads in this repository.

**Architecture:** A root `AGENTS.md` supplies concise operational instructions to Codex. It records the branch lifecycle and assigns models and reasoning effort to planning, implementation, and review roles.

**Tech Stack:** Git, GitHub pull requests, Codex multi-agent orchestration.

---

### Task 1: Add the repository workflow contract

**Files:**
- Create: `AGENTS.md`
- Test: `git diff --check`

**Step 1: Write the workflow contract**

Document the `develop`-first branch model, the use of feature branches and pull requests, role-specific model assignments, validation, and commit rules.

**Step 2: Verify the document has no whitespace errors**

Run: `git diff --check`

Expected: no output.

**Step 3: Commit the workflow contract**

Run: `git add AGENTS.md docs/plans/2026-10-13-agent-workflow-*.md && git commit -m "docs: add Codex agent workflow"`

Expected: one commit on `develop` containing the reusable instructions and their design records.
