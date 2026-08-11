#!/usr/bin/env bash
# Address human feedback posted on a PR (review or comment).
# Triggered by pull_request_review or issue_comment on a PR.
# Writes 'pr_number' to GITHUB_OUTPUT for the subsequent review cycle step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

# EVENT_PR_NUMBER is set explicitly by the target workflow for all PR events.
pr_number="${EVENT_PR_NUMBER:-}"
if [ -z "$pr_number" ] || [ "$pr_number" = "0" ]; then
  log "ERROR: EVENT_PR_NUMBER is not set. Cannot identify the PR."
  exit 1
fi
log "Addressing human PR feedback on PR #${pr_number}..."

# Derive the actual issue number from the PR branch (ai/issue-N-slug).
# If the branch doesn't follow that convention, we still address the feedback —
# we just won't have access to the originating issue's plan, title, or state.
branch=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json headRefName --jq '.headRefName')
issue_number=$(echo "$branch" | sed -n 's/.*ai\/issue-\([0-9]*\)-.*/\1/p' || true)

if [ -n "$issue_number" ]; then
  log "Derived issue #${issue_number} from branch ${branch}."
  export ISSUE_NUMBER="$issue_number"
else
  log "Cannot derive issue number from branch '${branch}' — proceeding without issue context."
fi

# Write outputs early so the review-cycle step has them even if we exit before the end.
echo "pr_number=${pr_number}" >> "$GITHUB_OUTPUT"
echo "issue_number=${issue_number}" >> "$GITHUB_OUTPUT"

# Collect human feedback: review bodies, inline comments, general PR comments
pr_reviews=$(gh api "repos/${TARGET_REPO}/pulls/${pr_number}/reviews" \
  --jq '[.[] | select(.user.type != "Bot" and (.body | length > 0)) | "**@\(.user.login) (\(.state)):**\n\(.body)"] | join("\n\n")' 2>/dev/null || echo "")

pr_line_comments=$(gh api "repos/${TARGET_REPO}/pulls/${pr_number}/comments" \
  --jq '[.[] | select(.user.type != "Bot") | "**@\(.user.login) on `\(.path)` line \(.line // .original_line // "N/A"):**\n\(.body)"] | join("\n\n")' 2>/dev/null || echo "")

pr_general_comments=$(gh api "repos/${TARGET_REPO}/issues/${pr_number}/comments" \
  --jq '[.[] | select(.user.type != "Bot") | select(.body | contains("<!-- ai-factory-bot -->") | not) | "**@\(.user.login):**\n\(.body)"] | join("\n\n")' 2>/dev/null || echo "")

feedback=$(printf '%s\n\n%s\n\n%s' "$pr_reviews" "$pr_line_comments" "$pr_general_comments" | sed '/^[[:space:]]*$/N;/^\n$/d')

if [ -z "$(echo "$feedback" | tr -d '[:space:]')" ]; then
  log "No human feedback found on PR #${pr_number}. Nothing to address."
  exit 0
fi

plan=""
issue_title=""
if [ -n "${ISSUE_NUMBER:-}" ]; then
  plan=$(get_plan_from_issue)
  issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
fi
pr_title=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json title --jq '.title')
claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

cd "$WORK_DIR"
git config user.email "software-factory[bot]@users.noreply.github.com"
git config user.name "software-factory[bot]"
git fetch origin "$branch"
git checkout "$branch"
agent_start_head=$(git rev-parse HEAD)

if [ -n "${ISSUE_NUMBER:-}" ]; then
  set_state "addressing-review"
fi

prompt_file=$(mktemp)
{
  cat "$FACTORY_DIR/prompts/implementer.md"
  echo ""
  echo "## Repository context (CLAUDE.md)"
  echo "${claude_md:-No CLAUDE.md found — infer test commands from project structure.}"
  echo ""
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    echo "## Original issue"
    echo "Title: ${issue_title}"
    echo ""
    echo "## Original implementation plan"
    echo "${plan}"
    echo ""
  else
    echo "## Pull request"
    echo "Title: ${pr_title}"
    echo ""
    echo "(No originating factory issue — work directly from the PR diff and human feedback below.)"
    echo ""
  fi
  echo "## Human feedback on the PR to address"
  echo "${feedback}"
  echo ""
  echo "Address each piece of feedback. Run tests after making changes."
} > "$prompt_file"

log "--- Claude addressing human PR feedback ---"
if ! run_claude "$prompt_file"; then
  log "Agent failed while addressing PR feedback."
  rm -f "$prompt_file"
else
  rm -f "$prompt_file"
fi

if ! git -C "$WORK_DIR" diff --quiet || \
   ! git -C "$WORK_DIR" diff --cached --quiet || \
   [ -n "$(git -C "$WORK_DIR" ls-files --others --exclude-standard)" ]; then
  git add -A
  summary=$(grep -m1 '^DONE:' "$CLAUDE_OUTPUT_FILE" | sed 's/^DONE:[[:space:]]*//' | cut -c1-120 || true)
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    commit_msg="fix: address human PR feedback for #${ISSUE_NUMBER}"
  else
    commit_msg="fix: address human PR feedback on PR #${pr_number}"
  fi
  [ -n "$summary" ] && commit_msg="${commit_msg} — ${summary}"
  git commit -m "$commit_msg"
fi

# The agent may have committed its own checkpoint, leaving a clean worktree.
# Push whenever HEAD advanced during this run rather than keying off git diff.
if [ "$(git rev-parse HEAD)" != "$agent_start_head" ]; then
  git push origin HEAD
  log "Changes committed and pushed."
  feedback_comment="## Human PR feedback addressed

$(cat "$CLAUDE_OUTPUT_FILE")"
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    post_comment "$feedback_comment"
  else
    post_pr_comment "$pr_number" "$feedback_comment"
  fi
else
  log "No commits created while addressing feedback."
fi
