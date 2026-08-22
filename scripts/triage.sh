#!/usr/bin/env bash
# Triage stage: classifies untriaged open issues and asks blocking questions.
# Runs on a schedule (or manually) — independent of the label-driven pipeline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared.sh"

refresh_github_token

MAX_TRIAGE_ISSUES="${MAX_TRIAGE_ISSUES:-10}"

triage_issues=$(list_untriaged_issues "$MAX_TRIAGE_ISSUES")

if [ -z "$triage_issues" ]; then
  log "No untriaged open issues found."
  echo "triaged_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

triaged_count=0

while read -r issue_number; do
  [ -n "$issue_number" ] || continue
  export ISSUE_NUMBER="$issue_number"

  log "Triaging issue #${ISSUE_NUMBER}..."
  issue_content=$(get_issue_content)
  issue_title=$(echo "$issue_content" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
  issue_body=$(echo "$issue_content" | python3 -c "import json,sys; print(json.load(sys.stdin)['body'])")

  prompt_file=$(mktemp)
  {
    cat "$FACTORY_DIR/prompts/triager.md"
    echo ""
    echo "## Repository context (CLAUDE.md)"
    echo "${claude_md:-No CLAUDE.md found — infer conventions from the codebase.}"
    echo ""
    echo "## Issue to triage"
    echo "Title: ${issue_title}"
    echo ""
    echo "${issue_body}"
  } > "$prompt_file"

  cd "$WORK_DIR"
  log "--- Claude triage agent output (issue #${ISSUE_NUMBER}) ---"
  # Redirect stdin so the agent cannot consume the issue list this loop reads.
  if ! run_claude "$prompt_file" "$TRIAGE_AGENT_MAX_TURNS" < /dev/null; then
    log "Triage agent failed on issue #${ISSUE_NUMBER}. Leaving it untriaged."
    rm -f "$prompt_file"
    continue
  fi
  rm -f "$prompt_file"

  output=$(cat "$CLAUDE_OUTPUT_FILE")
  if ! echo "$output" | grep -q "^TRIAGE:"; then
    log "Triage agent produced no TRIAGE block for issue #${ISSUE_NUMBER}. Leaving it untriaged."
    continue
  fi

  triage=$(echo "$output" | sed -n '/^TRIAGE:/,$p')
  issue_type=$(triage_field "$triage" "Type" | tr '[:upper:]' '[:lower:]')
  issue_size=$(triage_field "$triage" "Size" | tr '[:lower:]' '[:upper:]')
  issue_area=$(triage_field "$triage" "Area")
  summary=$(triage_field "$triage" "Summary")
  questions=$(triage_questions "$triage")

  if ! is_valid_triage_type "$issue_type" || ! is_valid_triage_size "$issue_size"; then
    log "Invalid classification for issue #${ISSUE_NUMBER} (type='${issue_type}', size='${issue_size}'). Leaving it untriaged."
    continue
  fi

  apply_triage_labels "$issue_type" "$issue_size"

  if [ -n "$questions" ]; then
    post_comment "## Triage

**Type:** ${issue_type} · **Size:** ${issue_size} · **Area:** ${issue_area:-none}

${summary}

These questions block implementation:

${questions}

Answer them here, then add the \`ai-factory\` label to start the pipeline."
  else
    post_comment "## Triage

**Type:** ${issue_type} · **Size:** ${issue_size} · **Area:** ${issue_area:-none}

${summary}

This issue is ready to implement as written. Add the \`ai-factory\` label to start the pipeline."
  fi

  mark_triaged
  triaged_count=$((triaged_count + 1))
done <<< "$triage_issues"

log "Triaged ${triaged_count} issue(s)."
echo "triaged_count=${triaged_count}" >> "$GITHUB_OUTPUT"
