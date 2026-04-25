#!/usr/bin/env bash
# Shared utilities for software factory pipeline scripts.
# Source this file; do not execute directly.

MAX_REVIEW_ROUNDS=3
BOT_LABEL="<!-- ai-factory-bot -->"
CLAUDE_OUTPUT_FILE="/tmp/last-claude-output.txt"

log() { echo "[factory] $*"; }

post_comment() {
  local body="$1"
  gh issue comment "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --body "${body}

${BOT_LABEL}"
}

post_pr_comment() {
  local pr_number="$1"
  local body="$2"
  gh pr comment "$pr_number" \
    --repo "$TARGET_REPO" \
    --body "${body}

${BOT_LABEL}"
}

get_issue_content() {
  gh issue view "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --json title,body,comments \
    --jq '{
      title: .title,
      body: .body,
      comments: [.comments[] | select(.body | contains("<!-- ai-factory-bot -->") | not) | .body]
    }'
}

get_plan_from_issue() {
  gh issue view "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --json comments \
    --jq '[.comments[] | select(.body | contains("<!-- ai-plan-start -->"))] | last | .body' \
  | sed -n '/<!-- ai-plan-start -->/,/<!-- ai-plan-end -->/p' \
  | sed '1d;$d'
}

get_review_round() {
  local pr_number="$1"
  gh pr view "$pr_number" \
    --repo "$TARGET_REPO" \
    --json body \
    --jq '.body' \
  | grep -oP '(?<=<!-- ai-review-round: )\d+' || echo "0"
}

set_review_round() {
  local pr_number="$1"
  local round="$2"
  local current_body
  current_body=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json body --jq '.body')
  local new_body
  if echo "$current_body" | grep -q "<!-- ai-review-round:"; then
    new_body=$(echo "$current_body" | sed "s/<!-- ai-review-round: [0-9]* -->/<!-- ai-review-round: ${round} -->/")
  else
    new_body="${current_body}

<!-- ai-review-round: ${round} -->"
  fi
  gh pr edit "$pr_number" --repo "$TARGET_REPO" --body "$new_body"
}

get_pr_for_issue() {
  gh pr list \
    --repo "$TARGET_REPO" \
    --json number,headRefName \
    --state open \
    --jq ".[] | select(.headRefName | startswith(\"ai/issue-${ISSUE_NUMBER}-\")) | .number" \
  2>/dev/null | head -1
}

# Run the Claude Code agent with streaming output.
# Prompt is read from prompt_file via stdin.
# All output is streamed live to the Actions log and saved to CLAUDE_OUTPUT_FILE for parsing.
run_claude() {
  local prompt_file="$1"
  local max_turns="${2:-500}"

  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  CLAUDE_MAX_TURNS="$max_turns" \
  CLAUDE_ALLOWED_TOOLS="Bash,Read,Write,Edit,Glob,Grep,LS" \
  WORK_DIR="$WORK_DIR" \
    node "$FACTORY_DIR/scripts/run-claude.mjs" \
    < "$prompt_file" \
    2>&1 | tee "$CLAUDE_OUTPUT_FILE"

  # Return the node script's exit code, not tee's
  return "${PIPESTATUS[0]}"
}
