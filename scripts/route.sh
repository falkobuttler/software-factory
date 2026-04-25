#!/usr/bin/env bash
# Determines what the pipeline should do based on the current event and issue state.
# Writes 'action' to GITHUB_OUTPUT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/shared.sh"

current_state=$(get_state)
log "Event: ${EVENT_NAME}/${EVENT_ACTION}, Label: '${LABEL_NAME:-}', State: ${current_state}, Issue: #${ISSUE_NUMBER}"

case "${EVENT_NAME}/${EVENT_ACTION}/${current_state}" in
  issues/labeled/new)
    if [ "${LABEL_NAME:-}" != "ai-factory" ]; then
      log "Label '${LABEL_NAME:-}' is not the factory trigger. Skipping."
      echo "action=noop" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    log "Trigger label detected. Starting pipeline."
    echo "action=plan" >> "$GITHUB_OUTPUT"
    ;;
  issue_comment/created/questioning)
    log "Human comment received while questioning. Resuming planning."
    echo "action=resume-plan" >> "$GITHUB_OUTPUT"
    ;;
  issue_comment/created/stuck)
    log "Human comment received while stuck. Resuming implementation."
    echo "action=resume-stuck" >> "$GITHUB_OUTPUT"
    ;;
  *)
    log "No action needed for this event/state combination."
    echo "action=noop" >> "$GITHUB_OUTPUT"
    ;;
esac
