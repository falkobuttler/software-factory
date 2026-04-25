#!/usr/bin/env bash
# Determines what the pipeline should do based on the current event and issue state.
# Writes 'action' to GITHUB_OUTPUT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

current_state=$(get_state)
log "Event: ${EVENT_NAME}/${EVENT_ACTION}, Label: '${LABEL_NAME:-}', State: ${current_state}, Issue: #${ISSUE_NUMBER}"

case "${EVENT_NAME}/${EVENT_ACTION}" in
  issues/labeled)
    if [ "${LABEL_NAME:-}" != "ai-factory" ]; then
      log "Label '${LABEL_NAME:-}' is not the factory trigger. Skipping."
      echo "action=noop" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    # Resume from wherever the issue currently is
    case "$current_state" in
      new)
        log "New issue. Starting pipeline from planning."
        echo "action=plan" >> "$GITHUB_OUTPUT"
        ;;
      questioning)
        log "Resuming from questioning → re-running planner with Q&A context."
        echo "action=resume-plan" >> "$GITHUB_OUTPUT"
        ;;
      implementing|stuck)
        log "Resuming from ${current_state} → jumping straight to implementation."
        echo "action=implement" >> "$GITHUB_OUTPUT"
        ;;
      reviewing|addressing-review)
        log "Resuming from ${current_state} → jumping straight to review cycle."
        echo "action=review" >> "$GITHUB_OUTPUT"
        ;;
      done)
        log "Issue is already marked done. Remove the ai:done label to restart."
        echo "action=noop" >> "$GITHUB_OUTPUT"
        ;;
      *)
        log "Unknown state '${current_state}'. Starting from planning."
        echo "action=plan" >> "$GITHUB_OUTPUT"
        ;;
    esac
    ;;
  issue_comment/created)
    case "$current_state" in
      questioning)
        log "Human comment received while questioning. Resuming planning."
        echo "action=resume-plan" >> "$GITHUB_OUTPUT"
        ;;
      stuck)
        log "Human comment received while stuck. Resuming implementation."
        echo "action=implement" >> "$GITHUB_OUTPUT"
        ;;
      *)
        log "Comment received but no action needed in state '${current_state}'."
        echo "action=noop" >> "$GITHUB_OUTPUT"
        ;;
    esac
    ;;
  *)
    log "No action needed for this event/state combination."
    echo "action=noop" >> "$GITHUB_OUTPUT"
    ;;
esac
