#!/usr/bin/env bats

load helpers

setup() {
  setup_shell_test
}

@test "get_state maps the first matching ai label to its state" {
  export GH_STUB_LABELS="bug,ai:reviewing,ai:stuck"
  run_function state.sh "get_state"
  [ "$status" -eq 0 ]
  [ "$output" = "reviewing" ]
}

@test "get_state returns new when there is no ai label" {
  export GH_STUB_LABELS="bug,enhancement"
  run_function state.sh "get_state"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]
}

@test "set_state removes existing ai labels and adds the new state label" {
  export GH_STUB_AI_LABELS="ai:planning,ai:stuck"
  run_function state.sh "set_state implementing"
  [ "$status" -eq 0 ]
  grep -F -- "--remove-label ai:planning,ai:stuck" "$GH_STUB_LOG"
  grep -F -- "--add-label ai:implementing" "$GH_STUB_LOG"
}

@test "set_state none removes existing ai labels without adding one" {
  export GH_STUB_AI_LABELS="ai:done"
  run_function state.sh "set_state none"
  [ "$status" -eq 0 ]
  grep -F -- "--remove-label ai:done" "$GH_STUB_LOG"
  ! grep -F -- "--add-label" "$GH_STUB_LOG"
}
