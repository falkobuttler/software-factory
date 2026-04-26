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

# Derive the actual issue number from the PR branch (ai/issue-N-slug)
branch=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json headRefName --jq '.headRefName')
issue_number=$(echo "$branch" | grep -oP '(?<=ai/issue-)\d+' || true)

if [ -z "$issue_number" ]; then
  log "ERROR: Cannot derive issue number from branch '${branch}' — not a factory-managed PR."
  exit 1
fi

log "Derived issue #${issue_number} from branch ${branch}."
export ISSUE_NUMBER="$issue_number"

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

plan=$(get_plan_from_issue)
issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

cd "$WORK_DIR"
git config user.email "software-factory[bot]@users.noreply.github.com"
git config user.name "software-factory[bot]"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_REPO}.git"
git fetch origin "$branch"
git checkout "$branch"

set_state "addressing-review"

prompt_file=$(mktemp)
{
  cat "$FACTORY_DIR/prompts/implementer.md"
  echo ""
  echo "## Repository context (CLAUDE.md)"
  echo "${claude_md:-No CLAUDE.md found — infer test commands from project structure.}"
  echo ""
  echo "## Original issue"
  echo "Title: ${issue_title}"
  echo ""
  echo "## Original implementation plan"
  echo "${plan}"
  echo ""
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
  git commit -m "fix: address human PR feedback for #${ISSUE_NUMBER}"
  git push origin HEAD
  log "Changes committed and pushed."
  post_comment "## Human PR feedback addressed

$(cat "$CLAUDE_OUTPUT_FILE")"
else
  log "No file changes after addressing feedback."
fi

echo "pr_number=${pr_number}" >> "$GITHUB_OUTPUT"
echo "issue_number=${issue_number}" >> "$GITHUB_OUTPUT"
