#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DISPATCHER="$ROOT/.github/workflows/dispatcher.yml"
  TRIAGE="$ROOT/.github/workflows/triage.yml"
  TRIAGE_TEMPLATE="$ROOT/target-repo-template/.github/workflows/software-factory-triage.yml"
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

@test "triage runs on the target repo without persisting credentials" {
  run grep -cF "uses: actions/checkout@" "$TRIAGE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  grep -F 'repository: ${{ inputs.target_repo }}' "$TRIAGE"
  grep -F "persist-credentials: false" "$TRIAGE"
  grep -F "uses: falkobuttler/software-factory@main" "$TRIAGE"
  grep -F 'scripts/triage.sh' "$TRIAGE"
}

@test "the triage template is scheduled and dispatchable" {
  grep -F 'cron: "0 3 * * *"' "$TRIAGE_TEMPLATE"
  grep -F "workflow_dispatch:" "$TRIAGE_TEMPLATE"
  grep -F "workflows/triage.yml@main" "$TRIAGE_TEMPLATE"
  grep -F 'target_repo: ${{ github.repository }}' "$TRIAGE_TEMPLATE"
}
