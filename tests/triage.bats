#!/usr/bin/env bats

load helpers

setup() {
  setup_shell_test
  TRIAGE_BLOCK=$'TRIAGE:\nType: Enhancement\nSize: m\nArea: scripts\nSummary: Add a nightly triage stage.\nQuestions:\n- Should closed issues be re-triaged?\n- Which label namespace should sizes use?'
}

@test "list_untriaged_issues skips triaged and in-flight issues" {
  export GH_STUB_ISSUE_LIST=$'7\n9'
  run_function shared.sh "list_untriaged_issues 5"
  [ "$status" -eq 0 ]
  [ "$output" = $'7\n9' ]
  grep -F -- "--limit 5" "$GH_STUB_LOG"
  grep -F -- "-label:ai-triaged -label:ai-factory" "$GH_STUB_LOG"
}

@test "triage_field reads classification fields from the agent block" {
  export TRIAGE_BLOCK
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/shared.sh'; triage_field \"\$TRIAGE_BLOCK\" Type; triage_field \"\$TRIAGE_BLOCK\" Size; triage_field \"\$TRIAGE_BLOCK\" Summary"
  [ "$status" -eq 0 ]
  [ "$output" = $'Enhancement\nm\nAdd a nightly triage stage.' ]
}

@test "triage_questions returns the question list" {
  export TRIAGE_BLOCK
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/shared.sh'; triage_questions \"\$TRIAGE_BLOCK\""
  [ "$status" -eq 0 ]
  [ "$output" = $'- Should closed issues be re-triaged?\n- Which label namespace should sizes use?' ]
}

@test "triage_questions is empty when the agent reports none" {
  export TRIAGE_BLOCK=$'TRIAGE:\nType: bug\nSize: XS\nQuestions: none'
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/shared.sh'; triage_questions \"\$TRIAGE_BLOCK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classification values are validated against the allowed sets" {
  run_function shared.sh "is_valid_triage_type enhancement"
  [ "$status" -eq 0 ]
  run_function shared.sh "is_valid_triage_type epic"
  [ "$status" -ne 0 ]
  run_function shared.sh "is_valid_triage_size XL"
  [ "$status" -eq 0 ]
  run_function shared.sh "is_valid_triage_size huge"
  [ "$status" -ne 0 ]
}

@test "apply_triage_labels adds the classification and clears stale sizes" {
  run_function shared.sh "apply_triage_labels bug S"
  [ "$status" -eq 0 ]
  grep -F -- "--add-label bug,size:S" "$GH_STUB_LOG"
  grep -F -- "--remove-label size:XS" "$GH_STUB_LOG"
  grep -F -- "--remove-label size:L" "$GH_STUB_LOG"
  ! grep -F -- "--remove-label size:S" "$GH_STUB_LOG"
}

@test "mark_triaged records the durable non-state label" {
  run_function shared.sh "mark_triaged"
  [ "$status" -eq 0 ]
  grep -F -- "--add-label ai-triaged" "$GH_STUB_LOG"

  # set_state wipes every ai: label, so the marker must not use that prefix.
  run_function shared.sh "printf '%s' \"\$TRIAGED_LABEL\""
  [ "$output" = "ai-triaged" ]
}

@test "triage stops before touching the target repo" {
  script="$BATS_TEST_DIRNAME/../scripts/triage.sh"
  prompt="$BATS_TEST_DIRNAME/../prompts/triager.md"

  grep -F "Triage is read-only." "$prompt"
  grep -F 'run_claude "$prompt_file" "$TRIAGE_AGENT_MAX_TURNS"' "$script"
  ! grep -E "git (commit|push|checkout)" "$script"
}

@test "triage leaves an issue untriaged when the agent output is unusable" {
  script="$BATS_TEST_DIRNAME/../scripts/triage.sh"

  grep -F 'if ! echo "$output" | grep -q "^TRIAGE:"; then' "$script"
  grep -F "Leaving it untriaged" "$script"
}
