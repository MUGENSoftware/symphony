---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and available in `PATH`.
- `gh auth status` succeeds for GitHub operations in this repo.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch, otherwise update the existing PR.
- Keep branch history clean when remote has moved.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.
2. Run local validation (`make -C elixir all`) before pushing.
3. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
4. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull`
     skill to merge `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

5. Resolve the GitHub default base branch explicitly:
   - Use `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
   - Do not rely on implicit base branch selection.
6. Draft the PR body into a temp file from `.github/pull_request_template.md`:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - If PR already exists, refresh body content so it reflects the total PR
     scope (all intended work on the branch), not just the newest commits,
     including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.
7. Validate the drafted PR body with `mix pr_body.check` before any PR
   create/edit command. If validation fails, stop and surface the error.
8. Ensure a PR exists for the branch:
   - If no PR exists, create one.
   - If a PR exists and is open, update it.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
   - Write a proper PR title that clearly describes the change outcome.
   - For branch updates, explicitly reconsider whether current PR title still
     matches the latest scope; update it if it no longer does.
9. Run PR create/edit non-interactively:
   - Never rely on `gh` prompts, editor launch, or interactive template
     selection.
   - Use explicit `--base`, `--title`, and `--body-file` flags.
10. Verify PR publication by reading back the PR URL with `gh pr view`.
    If URL retrieval fails, treat the publish step as failed and surface the
    exact error.
11. Reply with the PR URL from `gh pr view`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

# Minimal validation gate
make -C elixir all

# Initial push: respect the current origin remote.
git push -u origin HEAD

# If that failed because the remote moved, use the pull skill. After
# pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or workflow
# restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

# Resolve the repo default base branch explicitly.
base_branch=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

# Draft the PR body from the repo template and replace placeholders with
# concrete content for this change before validation.
tmp_pr_body=$(mktemp)
cp .github/pull_request_template.md "$tmp_pr_body"

# Edit "$tmp_pr_body" so every section is filled with concrete content and
# placeholder comments are removed before continuing.

# Validate the final PR body before any create/edit call.
(cd elixir && mix pr_body.check --file "$tmp_pr_body")

# Ensure a PR exists (create only if missing).
pr_state=$(gh pr view --json state,url -q .state 2>/dev/null || true)
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Current branch is tied to a closed PR; create a new branch + PR." >&2
  rm -f "$tmp_pr_body"
  exit 1
fi

# Write a clear, human-friendly title that summarizes the shipped change.
pr_title="<clear PR title written for this change>"
if [ -z "$pr_state" ]; then
  gh pr create --base "$base_branch" --title "$pr_title" --body-file "$tmp_pr_body"
else
  # Reconsider title on every branch update; edit if scope shifted. Keep the
  # update non-interactive by always providing the body file as well.
  gh pr edit --title "$pr_title" --body-file "$tmp_pr_body"
fi

# Verify publication immediately. If this fails, treat publish as failed rather
# than assuming PR creation succeeded.
pr_url=$(gh pr view --json url -q .url)
printf '%s\n' "$pr_url"
rm -f "$tmp_pr_body"
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
- Do not use `gh pr create` in a way that can prompt for missing inputs.
  PR creation/edit must stay fully non-interactive.
