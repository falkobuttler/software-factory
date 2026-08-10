#!/usr/bin/env bash
# Run a factory stage with the appropriate GitHub authentication source.
set -euo pipefail

case "${GITHUB_AUTH_MODE:-app}" in
  local)
    # Let gh and any gh-backed Git credential helper use the runner's durable
    # login instead of allowing a short-lived workflow token to override it.
    unset GH_TOKEN GITHUB_TOKEN APP_GH_TOKEN
    ;;
  app)
    app_token="${APP_GH_TOKEN:?APP_GH_TOKEN is required in app auth mode}"
    export GH_TOKEN="$app_token"
    unset APP_GH_TOKEN
    ;;
  *)
    echo "Unsupported GitHub authentication mode: ${GITHUB_AUTH_MODE}" >&2
    exit 1
    ;;
esac

exec "$@"
