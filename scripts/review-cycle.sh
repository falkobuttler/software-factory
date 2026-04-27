#!/usr/bin/env bash
# Review cycle: runs up to MAX_REVIEW_ROUNDS of AI review + address-feedback iterations,
# then marks the PR ready for human review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

# PR_NUMBER is set when coming from the Implement step; look it up when resuming directly.
pr_number="${PR_NUMBER:-}"
if [ -z "$pr_number" ]; then
  pr_number=$(get_pr_for_issue)
fi
if [ -z "$pr_number" ]; then
  log "ERROR: No open PR found for issue #${ISSUE_NUMBER}. Cannot run review cycle."
  post_comment "I couldn't find an open PR for this issue to review. Please check that the branch was pushed, then re-add the \`ai-factory\` label."
  exit 1
fi
log "Starting review cycle for PR #${pr_number}..."

issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

run_review() {
  local round="$1"
  set_state "reviewing"
  set_review_round "$pr_number" "$round"

  local plan base_branch diff
  plan=$(get_plan_from_issue)
  base_branch=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json baseRefName --jq '.baseRefName')
  diff=$(gh api "repos/${TARGET_REPO}/pulls/${pr_number}/files" \
    --jq '[.[] | "--- \(.filename)\n" + (.patch // "(binary)")] | join("\n\n")' 2>/dev/null \
    || git -C "$WORK_DIR" diff "origin/${base_branch}...HEAD")

  local prompt_file
  prompt_file=$(mktemp)
  {
    cat "$FACTORY_DIR/prompts/reviewer.md"
    echo ""
    echo "## Repository context (CLAUDE.md)"
    echo "${claude_md:-No CLAUDE.md found.}"
    echo ""
    echo "## Issue being addressed"
    echo "Title: ${issue_title}"
    echo ""
    echo "## Implementation plan"
    echo "${plan}"
    echo ""
    echo "## Pull request diff"
    echo "${diff}"
  } > "$prompt_file"

  cd "$WORK_DIR"
  log "--- Claude review agent output (round ${round}/${MAX_REVIEW_ROUNDS}) ---"
  if ! run_claude "$prompt_file" "20"; then
    log "Review agent failed. Marking PR ready for human review."
    rm -f "$prompt_file"
    return 1
  fi
  rm -f "$prompt_file"
  cat "$CLAUDE_OUTPUT_FILE"
}

address_feedback() {
  local round="$1"
  local feedback="$2"
  set_state "addressing-review"

  local plan
  plan=$(get_plan_from_issue)

  local prompt_file
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
    echo "## Code review feedback to address"
    echo "${feedback}"
    echo ""
    echo "Address each piece of feedback. Run tests after making changes."
  } > "$prompt_file"

  cd "$WORK_DIR"
  log "--- Claude addressing review feedback (round ${round}/${MAX_REVIEW_ROUNDS}) ---"
  if ! run_claude "$prompt_file"; then
    log "Address-feedback agent failed. Committing whatever exists."
    rm -f "$prompt_file"
  else
    rm -f "$prompt_file"
  fi

  if ! git -C "$WORK_DIR" diff --quiet || \
     ! git -C "$WORK_DIR" diff --cached --quiet || \
     [ -n "$(git -C "$WORK_DIR" ls-files --others --exclude-standard)" ]; then
    git -C "$WORK_DIR" add -A
    git -C "$WORK_DIR" commit -m "fix: address review feedback round ${round} for #${ISSUE_NUMBER}"
    git -C "$WORK_DIR" push origin HEAD
    log "Review feedback addressed and pushed."
  else
    log "No file changes after addressing feedback."
  fi
}

# ─── Review loop ─────────────────────────────────────────────────────────────

for round in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
  log "Review round ${round}/${MAX_REVIEW_ROUNDS}..."

  if ! run_review "$round"; then
    post_pr_comment "$pr_number" "Review agent encountered an error in round ${round}. Handing off for human review."
    break
  fi

  review_output=$(cat "$CLAUDE_OUTPUT_FILE")

  if echo "$review_output" | grep -q "^LGTM"; then
    log "Review passed on round ${round}!"
    post_pr_comment "$pr_number" "**Review passed** (round ${round}/${MAX_REVIEW_ROUNDS}) — marking PR ready for human review.

${review_output}"
    gh pr ready "$pr_number" --repo "$TARGET_REPO"
    set_state "done"
    post_comment "Implementation complete. PR #${pr_number} is ready for your review."
    exit 0
  fi

  post_pr_comment "$pr_number" "**Review round ${round}/${MAX_REVIEW_ROUNDS}** — changes requested:

${review_output}

$([ "$round" -lt "$MAX_REVIEW_ROUNDS" ] && echo 'Addressing feedback now...' || echo 'Max rounds reached — handing off for human review.')"

  if [ "$round" -lt "$MAX_REVIEW_ROUNDS" ]; then
    address_feedback "$round" "$review_output"
  fi
done

# Max rounds reached without LGTM
log "Max review rounds reached. Handing off to human."
gh pr ready "$pr_number" --repo "$TARGET_REPO"
set_state "done"
post_comment "Implementation complete (${MAX_REVIEW_ROUNDS} AI review rounds completed). PR #${pr_number} is ready for your review."
