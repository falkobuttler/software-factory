#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
}

@test "implementer checkpoints work and resolves compiler warnings" {
  prompt="$ROOT/prompts/implementer.md"

  grep -F "every compiler or build warning" "$prompt"
  grep -F "create a checkpoint commit" "$prompt"
  grep -F "including when the blocker is an unanswered question" "$prompt"
  grep -F "Do not push commits" "$prompt"
  grep -F "Do not run the complete unit-test suite after each change" "$prompt"
  grep -F "run the full unit-test suite once as the final verification step" "$prompt"
  ! grep -F "Do not commit anything" "$prompt"
}

@test "reviewer checkpoints changes and resolves compiler warnings" {
  prompt="$ROOT/prompts/reviewer.md"

  grep -F "every compiler or build warning" "$prompt"
  grep -F "create a checkpoint commit" "$prompt"
  grep -F "even if you still have questions" "$prompt"
  grep -F "Do not push commits" "$prompt"
  grep -F "Do not run the complete unit-test suite before making changes" "$prompt"
  grep -F "If you change any files while reviewing, run the full unit-test suite once after all of your changes are complete" "$prompt"
  grep -F "If you make no changes, do not rerun the full suite" "$prompt"
}
