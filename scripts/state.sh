#!/usr/bin/env bash
# State management for the software factory via GitHub issue labels.
# All AI-managed labels are prefixed with "ai:".
# Sourced by pipeline.sh — expects GH_TOKEN, TARGET_REPO, ISSUE_NUMBER in env.

AI_LABELS=(
  "ai:planning"
  "ai:questioning"
  "ai:implementing"
  "ai:reviewing"
  "ai:addressing-review"
  "ai:stuck"
  "ai:done"
)

LABEL_COLORS=(
  "ai:planning:0075ca"
  "ai:questioning:e4e669"
  "ai:implementing:d93f0b"
  "ai:reviewing:0e8a16"
  "ai:addressing-review:f9d0c4"
  "ai:stuck:b60205"
  "ai:done:0e8a16"
)

ensure_labels_exist() {
  for entry in "${LABEL_COLORS[@]}"; do
    name="${entry%%:*}"
    color="${entry##*:}"
    gh label create "$name" \
      --repo "$TARGET_REPO" \
      --color "$color" \
      --force 2>/dev/null || true
  done
}

get_state() {
  local labels
  labels=$(gh issue view "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --json labels \
    --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  for label in "${AI_LABELS[@]}"; do
    if echo "$labels" | grep -qF "$label"; then
      # Strip "ai:" prefix for the returned state name
      echo "${label#ai:}"
      return
    fi
  done
  echo "new"
}

set_state() {
  local new_state="$1"
  ensure_labels_exist

  # Remove all current ai: labels
  local current_labels
  current_labels=$(gh issue view "$ISSUE_NUMBER" \
    --repo "$TARGET_REPO" \
    --json labels \
    --jq '[.labels[] | select(.name | startswith("ai:")) | .name] | join(",")' 2>/dev/null || echo "")

  if [ -n "$current_labels" ]; then
    # gh issue edit --remove-label accepts comma-separated labels
    gh issue edit "$ISSUE_NUMBER" \
      --repo "$TARGET_REPO" \
      --remove-label "$current_labels" 2>/dev/null || true
  fi

  if [ "$new_state" != "none" ]; then
    gh issue edit "$ISSUE_NUMBER" \
      --repo "$TARGET_REPO" \
      --add-label "ai:${new_state}"
  fi
}
