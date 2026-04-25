#!/usr/bin/env bash
# Implementation stage: creates a branch, runs the implementation agent, commits, opens PR.
# Writes 'pr_number' and 'stuck' to GITHUB_OUTPUT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

log "Running implementation agent for issue #${ISSUE_NUMBER}..."
set_state "implementing"

plan=$(get_plan_from_issue)
if [ -z "$plan" ]; then
  log "ERROR: No plan found in issue comments."
  post_comment "I could not find my implementation plan. Please re-add the \`ai-factory\` label to restart."
  set_state "stuck"
  echo "stuck=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
issue_body=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json body --jq '.body')
claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

# Create or switch to branch
slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/-$//' | cut -c1-40)
branch="ai/issue-${ISSUE_NUMBER}-${slug}"

cd "$WORK_DIR"
git config user.email "software-factory[bot]@users.noreply.github.com"
git config user.name "software-factory[bot]"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_REPO}.git"

if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
  log "Branch ${branch} already exists remotely. Checking out."
  git fetch origin "$branch"
  git checkout "$branch"
else
  log "Creating branch ${branch}."
  git checkout -b "$branch"
fi

# Write prompt to a file (avoids shell argument length limits)
prompt_file=$(mktemp)
{
  cat "$FACTORY_DIR/prompts/implementer.md"
  echo ""
  echo "## Repository context (CLAUDE.md)"
  echo "${claude_md:-No CLAUDE.md found — infer test commands from project structure.}"
  echo ""
  echo "## Issue"
  echo "Title: ${issue_title}"
  echo ""
  echo "${issue_body}"
  echo ""
  echo "## Implementation plan"
  echo "${plan}"
} > "$prompt_file"

log "--- Claude implementation agent output ---"
if ! run_claude "$prompt_file"; then
  log "Implementation agent exited with an error. See output above."
  rm -f "$prompt_file"
  # Commit any partial progress before marking stuck
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    git commit -m "wip: partial progress on #${ISSUE_NUMBER} (agent error)" || true
    git push origin "$branch" || true
  fi
  post_comment "The implementation agent encountered an unexpected error. Please check the [workflow run]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions) for details, then reply here to resume."
  set_state "stuck"
  echo "stuck=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
rm -f "$prompt_file"

output=$(cat "$CLAUDE_OUTPUT_FILE")

if echo "$output" | grep -q "^STUCK:"; then
  stuck_reason=$(echo "$output" | sed -n '/^STUCK:/,$p')
  # Commit partial progress
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    git commit -m "wip: partial progress on #${ISSUE_NUMBER} (stuck)" || true
    git push origin "$branch" || true
  fi
  post_comment "I'm stuck and need your help:

${stuck_reason}

Please reply to this comment with guidance and I'll resume."
  set_state "stuck"
  echo "stuck=true" >> "$GITHUB_OUTPUT"
  log "Agent reported being stuck. Waiting for human guidance."
  exit 0
fi

# Commit all changes
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  log "WARNING: No file changes detected after implementation."
else
  git add -A
  git commit -m "feat: implement #${ISSUE_NUMBER}: ${issue_title}"
  git push origin "$branch"
  log "Changes committed and pushed to ${branch}."
fi

post_comment "## Implementation complete

$(cat "$CLAUDE_OUTPUT_FILE")"

# Open PR (idempotent)
pr_number=$(get_pr_for_issue)
if [ -z "$pr_number" ]; then
  pr_url=$(gh pr create \
    --repo "$TARGET_REPO" \
    --title "${issue_title}" \
    --body "Closes #${ISSUE_NUMBER}

<!-- ai-review-round: 0 -->" \
    --head "$branch" \
    --draft)
  pr_number=$(echo "$pr_url" | grep -oP '\d+$')
  log "Opened PR #${pr_number}."
else
  log "PR #${pr_number} already exists."
fi

echo "pr_number=${pr_number}" >> "$GITHUB_OUTPUT"
echo "stuck=false" >> "$GITHUB_OUTPUT"
