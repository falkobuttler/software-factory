#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DISPATCHER="$ROOT/.github/workflows/dispatcher.yml"
}

@test "dispatcher checks out only the target repository" {
  run grep -cF "uses: actions/checkout@" "$DISPATCHER"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  grep -F 'repository: ${{ inputs.target_repo }}' "$DISPATCHER"
  ! grep -F "path: target" "$DISPATCHER"
  ! grep -F "path: factory" "$DISPATCHER"
}

@test "factory runtime is downloaded as an action outside the worktree" {
  grep -F "uses: falkobuttler/software-factory@main" "$DISPATCHER"
  grep -F 'WORK_DIR: ${{ github.workspace }}' "$DISPATCHER"
  grep -F 'FACTORY_DIR: ${{ steps.factory-runtime.outputs.factory_dir }}' "$DISPATCHER"
  grep -F 'factory_dir=${GITHUB_ACTION_PATH}' "$ROOT/action.yml"
}

@test "self-hosted authentication preserves the checkout origin" {
  grep -F 'git config --local url."git@github.com:".insteadOf "https://github.com/"' "$DISPATCHER"
  ! grep -F "git remote set-url origin" "$DISPATCHER"
}
