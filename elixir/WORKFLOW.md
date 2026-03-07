---
tracker:
  kind: linear
  project_slug: "your project slug"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 8000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 "your project also here" .
    # if command -v mise >/dev/null 2>&1; then
    #   cd elixir && mise trust && mise exec -- mix deps.get
    # fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 10
claude:
  command: claude
  model: opus
  output_format: stream-json
  # Optional advanced override. If omitted, Symphony generates a default
  # MCP config for the blessed Linear server automatically.
  # mcp_config: /absolute/path/to/custom-claude.mcp.json
  dangerously_skip_permissions: true
  max_turns: 10
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Avoid redoing completed investigation or validation unless required by new changes.
- Do not end while the issue remains active unless blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Stop early only for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to this workflow.
3. Final message must include completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear tools are available through MCP

In `stream-json` sessions, Symphony provides Linear access through the configured MCP server.
If no Linear MCP tools are available, stop and report that the MCP setup is missing or broken.

## Operating profile: Balanced (default)

- Keep the status model unchanged: `Todo/In Progress/In Review/Rework/Merging/Done`.
- Route execution by complexity:
  - `Simple`: touches at most 2 files, no migration/schema change, no public API/contract change, no security-critical change.
  - `Standard`: any ticket that does not match `Simple`.
- Auto-upgrade to `Standard` immediately when risk appears (contract/API, migration/schema, security, broad cross-cutting changes).
- Use one persistent Linear comment as source of truth: `## Claude Workpad`.
- Post workpad updates by milestones only, not by timer:
  - execution start,
  - scope/risk change,
  - validation final,
  - true blocker.
- If ticket includes `Validation`, `Test Plan`, or `Testing`, mirror those items into workpad and execute them before completion.
- Keep scope tight. If meaningful out-of-scope work is found, create a separate `Backlog` issue with clear title/description/acceptance criteria and link it as `related` (`blockedBy` only if dependency exists).

## Related skills

- `linear`: optional repository guidance for raw Linear GraphQL work when MCP tools are present.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.claude/skills/land/SKILL.md`, which includes the `land` loop.

Use skills conditionally by phase and complexity. For `Simple`, avoid unnecessary skill loops.

## Status map

- `Backlog` -> out of scope; do not modify.
- `Todo` -> queued; move to `In Progress` before active work.
  - If a PR is already attached, run the PR feedback sweep before closing execution.
- `In Progress` -> active implementation.
- `In Review` -> PR attached and validated; waiting on human review.
- `Merging` -> approved by human; execute `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; execute rework flow.
- `Done` -> terminal; no further action.

## Step 0: Route by state

1. Fetch issue by explicit ticket ID.
2. Read current state.
3. Route:
   - `Backlog`: stop and wait for human to move to `Todo`.
   - `Todo`: move to `In Progress`, ensure workpad exists, then execute.
   - `In Progress`: continue from workpad.
   - `In Review`: wait and poll for review decision.
   - `Merging`: follow `.claude/skills/land/SKILL.md` and run `land` loop.
   - `Rework`: follow rework flow.
   - `Done`: do nothing and shut down.
4. If branch PR exists and is `CLOSED` or `MERGED`, do not reuse it. Create a fresh branch from `origin/main` and restart execution.
5. If state and issue content conflict, add a short note in the workpad and proceed with the safest flow.

## Step 1: Start/continue execution (`Todo` or `In Progress`)

1. Find or create one active `## Claude Workpad` comment. Reuse it if it already exists.
2. Add/update compact environment stamp at top:
   - `<host>:<abs-workdir>@<short-sha>`
3. Classify complexity and record it in workpad (`Complexity: Simple|Standard`).
4. Build/update the plan according to complexity:
   - `Simple`: mini-plan with 3-5 bullets.
   - `Standard`: fuller hierarchical plan with parent/child checklist.
5. Add acceptance criteria and validation checklist in workpad.
6. Mirror any ticket-authored `Validation/Test Plan/Testing` items into required checkboxes.
7. Run `pull` sync before edits and record result in `Notes` (source, `clean`/`conflicts resolved`, resulting short SHA).
8. Post milestone update in workpad: `execution start`.

## Reproduction and validation policy

- `Simple`: reproduction is optional when issue signal is already explicit in ticket context and fix target is unambiguous.
- `Standard`: capture a concrete reproduction signal before code edits when feasible.
- Always run relevant validation before push/review:
  - `Simple`: focused validation for changed behavior.
  - `Standard`: broader validation proportional to impact.
- Ticket-provided validation requirements are mandatory in both modes.

## PR feedback sweep protocol (required when PR exists)

Before moving to `In Review`, if a PR is attached:

1. Identify PR number from issue links/attachments.
2. Collect feedback from:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable comment (human or bot) as blocking until resolved by:
   - code/test/docs update, or
   - explicit justified pushback reply.
4. Update workpad checklist with feedback resolution status.
5. Re-run relevant validation after feedback changes.
6. Repeat until no actionable comments remain.

## Step 2: Execution phase (`In Progress` -> `In Review`)

1. Confirm repo state (`branch`, `git status`, `HEAD`) and keep workpad as the active checklist.
2. Implement scoped changes.
3. Update workpad at milestone boundaries only:
   - scope/risk change,
   - validation final,
   - blocker.
4. Keep checklists accurate (plan, acceptance, validation).
5. Before each `git push`, run required validation for current scope and ensure green.
6. Publish phase (explicit):
   - Run `push` skill (or equivalent commands) to push branch and create/update PR.
   - On success, require a concrete PR URL via `gh pr view --json url -q .url`.
   - Attach PR URL to issue (prefer attachment) and ensure PR label `symphony`.
7. PR existence check before transition:
   - If PR URL exists, continue with normal feedback sweep/checks flow.
   - If PR URL is missing due to GitHub auth/permission/repo policy error, record blocker details in workpad and move issue to `In Review` using the publish-blocker path.
8. Stuck-session guardrail:
   - If branch has new commits but no PR URL after publish attempts/fallbacks, do not keep retrying in `In Progress`.
   - Record exact command(s), stderr, and fallback attempts in workpad, then move issue to `In Review` as blocked.
9. Merge latest `origin/main` into branch, resolve conflicts, and rerun relevant checks.
10. Finalize workpad with completed checklist + concise validation evidence.
11. Move to `In Review` only when completion bar is satisfied.

## Blocked-access escape hatch

Use only for true external blockers that cannot be resolved in-session.

- GitHub access is not a blocker by default for normal sync/push issues; attempt reasonable fallback strategies first.
- Explicit exception: PR creation/update failures caused by GitHub auth/permissions/repo policy are valid blockers after fallback attempts and should follow the publish-blocker path.
- If required non-GitHub tooling/auth is missing, move to `In Review` with concise blocker brief in workpad:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact action needed to unblock.

## Step 3: `In Review` and merge handling

1. In `In Review`, do not code or change ticket scope.
2. Poll for review updates and PR feedback.
3. If feedback requires changes, move to `Rework`.
4. If approved, human moves issue to `Merging`.
5. In `Merging`, run `land` skill loop from `.claude/skills/land/SKILL.md` (never `gh pr merge` directly).
6. After merge, move issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a fresh attempt with updated approach.
2. Re-read issue body and review feedback; record what changes this attempt.
3. Close prior PR tied to the issue.
4. Remove old `## Claude Workpad` comment.
5. Create fresh branch from `origin/main`.
6. Restart from normal kickoff flow.

## Completion bar before `In Review`

- Workpad checklist reflects actual completed work.
- Acceptance criteria are complete.
- Required ticket-provided validation items are complete.
- Relevant validation is green for latest commit.
- Normal path: PR exists, is linked to issue, has label `symphony`, and (if applicable) feedback sweep/checks are complete.
- Soft-gate blocker path: PR may be missing only when publish blocker is explicitly documented in workpad with command, stderr, attempted fallback, and required human unblock action.

## Guardrails

- Do not change state semantics.
- Do not edit issue body for planning/progress tracking.
- Keep exactly one persistent `## Claude Workpad` comment per issue.
- If branch PR is closed/merged, do not reuse branch state.
- Do not expand scope with opportunistic refactors.
- If blocked and no workpad exists yet, create one blocker comment with impact and unblock action.

## Workpad template

Use this structure and keep it updated in place:

````md
## Claude Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Mode

- Complexity: `Simple` or `Standard`

### Plan

- [ ] Task 1
- [ ] Task 2

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] command/result evidence

### Notes

- [timestamp] milestone update

### Confusions

- <only when needed>
````
