#!/usr/bin/env bash
# Shared utilities for software factory pipeline scripts.
# Source this file; do not execute directly.

MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
DEFAULT_AGENT_MAX_TURNS="${DEFAULT_AGENT_MAX_TURNS:-500}"
REVIEW_AGENT_MAX_TURNS="${REVIEW_AGENT_MAX_TURNS:-100}"
TRIAGE_AGENT_MAX_TURNS="${TRIAGE_AGENT_MAX_TURNS:-40}"
BOT_LABEL="<!-- ai-factory-bot -->"
# Marker label, deliberately not "ai:"-prefixed: set_state clears every "ai:"
# label, and triage must survive the whole pipeline so issues are triaged once.
TRIAGED_LABEL="ai-triaged"
TRIAGE_TYPES=(bug enhancement documentation question chore)
TRIAGE_SIZES=(XS S M L XL)
CLAUDE_OUTPUT_FILE="/tmp/last-claude-output.txt"

log() { echo "[factory] $*"; }

# GitHub App installation tokens expire after one hour. Long implementation and
# review agents can cross that boundary, so renew the API token around every
# long-running agent call instead of relying on the token created at job start.
refresh_github_token() {
  local refreshed_token
  refreshed_token=$(node "$FACTORY_DIR/scripts/create-app-token.mjs")
  echo "::add-mask::${refreshed_token}"
  export GH_TOKEN="$refreshed_token"
  log "Refreshed GitHub App token."
}

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
  | grep -oE '<!-- ai-review-round: [0-9]+ -->' | grep -oE '[0-9]+' || echo "0"
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

# Open issues that have never been triaged and are not already in the pipeline.
list_untriaged_issues() {
  local limit="${1:-10}"
  gh issue list \
    --repo "$TARGET_REPO" \
    --state open \
    --limit "$limit" \
    --search "-label:${TRIAGED_LABEL} -label:ai-factory sort:created-asc" \
    --json number \
    --jq '.[].number'
}

# Reads a "Field: value" line out of the agent's TRIAGE block.
triage_field() {
  local triage="$1"
  local field="$2"
  echo "$triage" | sed -n "s/^${field}:[[:space:]]*//p" | head -1
}

# Everything under "Questions:" as a markdown list, or empty when there are none.
triage_questions() {
  local triage="$1"
  local questions
  questions=$(echo "$triage" | sed -n '/^Questions:/,$p' | sed '1d' | grep -E '^[[:space:]]*-' || true)
  if [ "$(triage_field "$triage" "Questions" | tr '[:upper:]' '[:lower:]')" = "none" ]; then
    return 0
  fi
  echo "$questions"
}

is_valid_triage_type() {
  local candidate="$1"
  local value
  for value in "${TRIAGE_TYPES[@]}"; do
    [ "$candidate" = "$value" ] && return 0
  done
  return 1
}

is_valid_triage_size() {
  local candidate="$1"
  local value
  for value in "${TRIAGE_SIZES[@]}"; do
    [ "$candidate" = "$value" ] && return 0
  done
  return 1
}

apply_triage_labels() {
  local issue_type="$1"
  local issue_size="$2"
  gh label create "$issue_type" --repo "$TARGET_REPO" --color "d4c5f9" --force >/dev/null 2>&1 || true
  gh label create "size:${issue_size}" --repo "$TARGET_REPO" --color "c2e0c6" --force >/dev/null 2>&1 || true
  # A re-triaged issue must not keep a stale size, so drop the other size labels.
  local value
  for value in "${TRIAGE_SIZES[@]}"; do
    [ "$value" = "$issue_size" ] && continue
    gh issue edit "$ISSUE_NUMBER" --repo "$TARGET_REPO" --remove-label "size:${value}" >/dev/null 2>&1 || true
  done
  gh issue edit "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --add-label "${issue_type},size:${issue_size}"
}

mark_triaged() {
  gh label create "$TRIAGED_LABEL" --repo "$TARGET_REPO" --color "ededed" --force >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --repo "$TARGET_REPO" --add-label "$TRIAGED_LABEL"
}

# Run the Claude Code agent with real-time streaming output.
# Output is written to stdout as it arrives AND saved to CLAUDE_OUTPUT_FILE.
run_claude() {
  local prompt_file="$1"
  local max_turns="${2:-$DEFAULT_AGENT_MAX_TURNS}"
  local agent_status=0

  # Keep the App's private key and API token in the orchestration shell only;
  # the coding agent does not need either credential to edit and test code.
  (
    unset APP_ID APP_PRIVATE_KEY GH_TOKEN GITHUB_TOKEN
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
      node "$FACTORY_DIR/scripts/run-claude.mjs" "$prompt_file" "$max_turns"
  ) || agent_status=$?

  # The agent may have run for close to or beyond the token lifetime. Refresh
  # before its caller posts comments, updates state, or starts another round.
  refresh_github_token
  return "$agent_status"
}
