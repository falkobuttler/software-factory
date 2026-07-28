#!/usr/bin/env bash
# Main orchestration script for the software factory pipeline.
#
# Required env vars:
#   TARGET_REPO       - "owner/repo" of the target repository
#   ISSUE_NUMBER      - GitHub issue number to work on
#   EVENT_NAME        - GitHub event: "issues" or "issue_comment"
#   EVENT_ACTION      - GitHub action: "labeled" or "created"
#   LABEL_NAME        - Name of the label added (for issues.labeled events)
#   COMMENT_BODY      - Body of the triggering comment (empty for non-comment events)
#   GH_TOKEN          - GitHub App installation token
#   ANTHROPIC_API_KEY - Anthropic API key for Claude Code
#   WORK_DIR          - Absolute path to checked-out target repo
#   FACTORY_DIR       - Absolute path to checked-out factory repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"

MAX_REVIEW_ROUNDS=3
BOT_LABEL="<!-- ai-factory-bot -->"

# ─── Helpers ────────────────────────────────────────────────────────────────

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

run_claude() {
  local prompt_file="$1"
  local extra_args="${2:-}"
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    claude --print \
    --max-turns 50 \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep,LS" \
    $extra_args \
    < "$prompt_file"
}

# ─── Pipeline steps ─────────────────────────────────────────────────────────

run_planner() {
  log "Running planning agent for issue #${ISSUE_NUMBER}..."
  set_state "planning"

  local issue_content claude_md=""
  issue_content=$(get_issue_content)

  if [ -f "$WORK_DIR/CLAUDE.md" ]; then
    claude_md=$(cat "$WORK_DIR/CLAUDE.md")
  fi

  local qa_context=""
  if [ "${EVENT_NAME}" = "issue_comment" ]; then
    qa_context=$(get_issue_content | python3 -c "
import json,sys
data = json.load(sys.stdin)
print('\n\n## Q&A from issue comments\n' + '\n'.join(data['comments']))
")
  fi

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" << PROMPT
$(cat "$FACTORY_DIR/prompts/planner.md")

## Repository context (CLAUDE.md)
${claude_md:-No CLAUDE.md found — infer conventions from the codebase.}

## Issue to implement
Title: $(echo "$issue_content" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['title'])")

$(echo "$issue_content" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['body'])")
${qa_context}
PROMPT

  cd "$WORK_DIR"
  local output
  output=$(run_claude "$prompt_file")
  rm -f "$prompt_file"

  if echo "$output" | grep -q "^QUESTIONS:"; then
    local questions
    questions=$(echo "$output" | sed -n '/^QUESTIONS:/,/^[A-Z][A-Z]*:/{ /^[A-Z][A-Z]*:/!p }' | grep -v "^QUESTIONS:" || echo "$output" | sed -n '/^QUESTIONS:/,$p')

    post_comment "I have a few questions before I start planning:

${questions}

I'll resume planning once these are answered."

    set_state "questioning"
    log "Posted questions, waiting for answers."
    return 0
  fi

  local plan
  plan=$(echo "$output" | sed -n '/^PLAN:/,$p')

  post_comment "## Implementation Plan

<!-- ai-plan-start -->
${plan}
<!-- ai-plan-end -->

Starting implementation..."

  set_state "implementing"
  run_implementer
}

run_implementer() {
  log "Running implementation agent for issue #${ISSUE_NUMBER}..."

  local plan
  plan=$(get_plan_from_issue)
  if [ -z "$plan" ]; then
    log "ERROR: Could not find plan in issue comments."
    post_comment "I could not find my implementation plan. Please re-assign the issue to restart."
    set_state "stuck"
    return 1
  fi

  local issue_title issue_body claude_md=""
  issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
  issue_body=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json body --jq '.body')

  if [ -f "$WORK_DIR/CLAUDE.md" ]; then
    claude_md=$(cat "$WORK_DIR/CLAUDE.md")
  fi

  # Create branch
  local slug
  slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40 | sed 's/-$//')
  local branch="ai/issue-${ISSUE_NUMBER}-${slug}"

  cd "$WORK_DIR"

  # Set up git
  git config user.email "software-factory[bot]@users.noreply.github.com"
  git config user.name "software-factory[bot]"
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_REPO}.git"

  # Create or switch to branch
  if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
    git fetch origin "$branch"
    git checkout "$branch"
  else
    git checkout -b "$branch"
  fi

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" << PROMPT
$(cat "$FACTORY_DIR/prompts/implementer.md")

## Repository context (CLAUDE.md)
${claude_md:-No CLAUDE.md found — infer test commands from project structure.}

## Issue
Title: ${issue_title}

${issue_body}

## Implementation plan
${plan}
PROMPT

  local output
  output=$(run_claude "$prompt_file")
  rm -f "$prompt_file"

  if echo "$output" | grep -q "^STUCK:"; then
    local stuck_reason
    stuck_reason=$(echo "$output" | sed -n '/^STUCK:/,$p')

    post_comment "I'm stuck and need your help:

${stuck_reason}

Please reply to this comment with guidance and I'll resume."

    # Commit whatever partial progress exists
    if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
      git add -A
      git commit -m "wip: partial progress on #${ISSUE_NUMBER} (stuck)" || true
      git push origin "$branch" || true
    fi

    set_state "stuck"
    return 0
  fi

  # Commit all changes
  if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    log "WARNING: No file changes detected after implementation."
  else
    git add -A
    git commit -m "feat: implement #${ISSUE_NUMBER}: ${issue_title}"
    git push origin "$branch"
  fi

  # Open PR (idempotent)
  local pr_number
  pr_number=$(get_pr_for_issue)
  if [ -z "$pr_number" ]; then
    local pr_url
    pr_url=$(gh pr create \
      --repo "$TARGET_REPO" \
      --title "${issue_title}" \
      --body "Closes #${ISSUE_NUMBER}

<!-- ai-review-round: 0 -->" \
      --head "$branch" \
      --draft)
    pr_number=$(echo "$pr_url" | grep -oP '\d+$')
    log "Created PR #${pr_number}"
  else
    log "PR #${pr_number} already exists, pushing to it."
  fi

  set_state "reviewing"
  run_review_loop "$pr_number"
}

run_review_loop() {
  local pr_number="$1"
  local round=0

  while [ "$round" -lt "$MAX_REVIEW_ROUNDS" ]; do
    round=$((round + 1))
    set_review_round "$pr_number" "$round"
    set_state "reviewing"

    log "Running review agent (round ${round}/${MAX_REVIEW_ROUNDS})..."

    local base_branch diff claude_md="" issue_title plan
    base_branch=$(gh pr view "$pr_number" --repo "$TARGET_REPO" --json baseRefName --jq '.baseRefName')
    diff=$(gh api "repos/${TARGET_REPO}/pulls/${pr_number}/files" --jq '[.[] | "--- \(.filename)\n" + .patch] | join("\n\n")' 2>/dev/null || git diff "origin/${base_branch}...HEAD")
    issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
    plan=$(get_plan_from_issue)

    if [ -f "$WORK_DIR/CLAUDE.md" ]; then
      claude_md=$(cat "$WORK_DIR/CLAUDE.md")
    fi

    local prompt_file
    prompt_file=$(mktemp)
    cat > "$prompt_file" << PROMPT
$(cat "$FACTORY_DIR/prompts/reviewer.md")

## Repository context (CLAUDE.md)
${claude_md:-No CLAUDE.md found.}

## Issue being addressed
Title: ${issue_title}

## Implementation plan
${plan}

## Pull request diff
${diff}
PROMPT

    cd "$WORK_DIR"
    local review_output
    review_output=$(run_claude "$prompt_file" "--max-turns 50")
    rm -f "$prompt_file"

    if echo "$review_output" | grep -q "^LGTM"; then
      log "Review passed! Marking PR ready."
      post_pr_comment "$pr_number" "Code review passed. Marking PR ready for human review.

${review_output}"
      gh pr ready "$pr_number" --repo "$TARGET_REPO"
      set_state "done"
      post_comment "Implementation complete. PR #${pr_number} is ready for your review."
      return 0
    fi

    local changes_requested
    changes_requested=$(echo "$review_output" | sed -n '/^CHANGES_REQUESTED:/,$p')

    post_pr_comment "$pr_number" "**Review round ${round}/${MAX_REVIEW_ROUNDS}** — changes requested:

${changes_requested}

Addressing feedback now..."

    if [ "$round" -lt "$MAX_REVIEW_ROUNDS" ]; then
      set_state "addressing-review"
      address_review_feedback "$pr_number" "$changes_requested"
    fi
  done

  # Max rounds reached — hand off to human
  log "Max review rounds reached. Handing off to human."
  gh pr ready "$pr_number" --repo "$TARGET_REPO"
  post_pr_comment "$pr_number" "Reached maximum of ${MAX_REVIEW_ROUNDS} AI review rounds. Handing off for human review. Outstanding feedback has been noted above."
  set_state "done"
  post_comment "Implementation complete (max AI review rounds reached). PR #${pr_number} is ready for your review."
}

address_review_feedback() {
  local pr_number="$1"
  local feedback="$2"

  log "Running implementation agent to address review feedback..."

  local claude_md="" issue_title plan
  issue_title=$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json title --jq '.title')
  plan=$(get_plan_from_issue)

  if [ -f "$WORK_DIR/CLAUDE.md" ]; then
    claude_md=$(cat "$WORK_DIR/CLAUDE.md")
  fi

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" << PROMPT
$(cat "$FACTORY_DIR/prompts/implementer.md")

## Repository context (CLAUDE.md)
${claude_md:-No CLAUDE.md found — infer test commands from project structure.}

## Original issue
Title: ${issue_title}

## Original implementation plan
${plan}

## Code review feedback to address
${feedback}

Address each piece of feedback. Run tests after making changes to verify nothing is broken.
PROMPT

  cd "$WORK_DIR"
  local output
  output=$(run_claude "$prompt_file")
  rm -f "$prompt_file"

  if echo "$output" | grep -q "^STUCK:"; then
    local stuck_reason
    stuck_reason=$(echo "$output" | sed -n '/^STUCK:/,$p')
    post_pr_comment "$pr_number" "I got stuck addressing the review feedback:

${stuck_reason}

Handing off to human review."
    gh pr ready "$pr_number" --repo "$TARGET_REPO"
    set_state "done"
    return 0
  fi

  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    git commit -m "fix: address review feedback for #${ISSUE_NUMBER}"
    git push origin HEAD
  fi
}

# ─── Router ─────────────────────────────────────────────────────────────────

main() {
  local current_state
  current_state=$(get_state)
  log "Event: ${EVENT_NAME}/${EVENT_ACTION}, State: ${current_state}, Issue: #${ISSUE_NUMBER}"

  case "${EVENT_NAME}/${EVENT_ACTION}/${current_state}" in
    issues/labeled/new)
      if [ "${LABEL_NAME}" != "ai-factory" ]; then
        log "Label '${LABEL_NAME}' is not the factory trigger. Skipping."
        exit 0
      fi
      run_planner
      ;;
    issue_comment/created/questioning)
      # Human answered questions — resume planning with full Q&A context
      run_planner
      ;;
    issue_comment/created/stuck)
      # Human provided help — resume from implementation
      set_state "implementing"
      run_implementer
      ;;
    *)
      log "No action for event=${EVENT_NAME} action=${EVENT_ACTION} state=${current_state}. Skipping."
      ;;
  esac
}

main
