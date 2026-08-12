#!/usr/bin/env bash
# Planning stage: reads the issue, runs the planning agent, posts the plan or questions.
# Writes 'has_questions' to GITHUB_OUTPUT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

refresh_github_token

log "Running planning agent for issue #${ISSUE_NUMBER}..."
set_state "planning"

issue_content=$(get_issue_content)
claude_md=""
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  claude_md=$(cat "$WORK_DIR/CLAUDE.md")
fi

qa_context=""
if [ "${EVENT_NAME}" = "issue_comment" ]; then
  qa_context=$(echo "$issue_content" | python3 -c "
import json, sys
data = json.load(sys.stdin)
comments = '\n\n'.join(data['comments'])
print('\n\n## Q&A from issue comments\n' + comments)
" 2>/dev/null || true)
fi

issue_title=$(echo "$issue_content" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
issue_body=$(echo "$issue_content" | python3 -c "import json,sys; print(json.load(sys.stdin)['body'])")

prompt_file=$(mktemp)
cat > "$prompt_file" << 'HEREDOC_END'
PLANNER_PROMPT_PLACEHOLDER
HEREDOC_END

# Write the actual prompt (avoids heredoc injection from issue content)
{
  cat "$FACTORY_DIR/prompts/planner.md"
  echo ""
  echo "## Repository context (CLAUDE.md)"
  echo "${claude_md:-No CLAUDE.md found — infer conventions from the codebase.}"
  echo ""
  echo "## Issue to implement"
  echo "Title: ${issue_title}"
  echo ""
  echo "${issue_body}"
  echo "${qa_context}"
} > "$prompt_file"

cd "$WORK_DIR"
log "--- Claude planning agent output ---"
if ! run_claude "$prompt_file"; then
  log "Planning agent failed. See output above."
  rm -f "$prompt_file"
  exit 1
fi
rm -f "$prompt_file"

output=$(cat "$CLAUDE_OUTPUT_FILE")

if echo "$output" | grep -q "^QUESTIONS:"; then
  questions=$(echo "$output" | sed -n '/^QUESTIONS:/,$p')
  post_comment "I have a few questions before I start planning:

${questions}

I'll resume once these are answered."
  set_state "questioning"
  echo "has_questions=true" >> "$GITHUB_OUTPUT"
  log "Questions posted. Waiting for answers."
else
  plan=$(echo "$output" | sed -n '/^PLAN:/,$p')
  post_comment "## Implementation Plan

<!-- ai-plan-start -->
${plan}
<!-- ai-plan-end -->

Starting implementation..."
  set_state "implementing"
  echo "has_questions=false" >> "$GITHUB_OUTPUT"
  log "Plan posted. Proceeding to implementation."
fi
