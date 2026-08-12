#!/usr/bin/env bats

load helpers

setup() {
  setup_shell_test
}

@test "agent turn limits are centralized and the review cycle uses the review limit" {
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/shared.sh'; printf '%s %s' \"\$DEFAULT_AGENT_MAX_TURNS\" \"\$REVIEW_AGENT_MAX_TURNS\""
  [ "$status" -eq 0 ]
  [ "$output" = "500 100" ]

  grep -F 'run_claude "$prompt_file" "$REVIEW_AGENT_MAX_TURNS"' \
    "$BATS_TEST_DIRNAME/../scripts/review-cycle.sh"
  ! grep -F 'run_claude "$prompt_file" "20"' \
    "$BATS_TEST_DIRNAME/../scripts/review-cycle.sh"
}

@test "get_plan_from_issue extracts the plan from the last plan comment" {
  export GH_STUB_PLAN_BODY=$'old\n<!-- ai-plan-start -->\nold plan\n<!-- ai-plan-end -->\nnew\n<!-- ai-plan-start -->\nlatest plan\n<!-- ai-plan-end -->'
  run_function shared.sh "get_plan_from_issue"
  [ "$status" -eq 0 ]
  [ "$output" = "latest plan" ]
}

@test "get_review_round extracts the review round and defaults to zero" {
  export GH_STUB_PR_BODY='Summary <!-- ai-review-round: 2 -->'
  run_function shared.sh "get_review_round 7"
  [ "$output" = "2" ]
  export GH_STUB_PR_BODY="No marker"
  run_function shared.sh "get_review_round 7"
  [ "$output" = "0" ]
}

@test "set_review_round replaces an existing marker" {
  export GH_STUB_PR_BODY=$'PR body\n<!-- ai-review-round: 1 -->'
  run_function shared.sh "set_review_round 7 3"
  [ "$status" -eq 0 ]
  grep -F -- "--body PR body" "$GH_STUB_LOG"
  grep -F -- "ai-review-round:" "$GH_STUB_LOG" | grep -F "3"
}

@test "set_review_round appends a marker when none exists" {
  export GH_STUB_PR_BODY="PR body"
  run_function shared.sh "set_review_round 7 1"
  [ "$status" -eq 0 ]
  grep -F -- "ai-review-round:" "$GH_STUB_LOG" | grep -F "1"
}

@test "get_issue_content returns the gh-provided filtered issue content" {
  export GH_STUB_ISSUE_CONTENT_RAW='{"title":"Issue","body":"Description","comments":[{"body":"human comment"},{"body":"bot <!-- ai-factory-bot -->"}]}'
  run_function shared.sh "get_issue_content"
  [ "$status" -eq 0 ]
  [ "$output" = '{"title":"Issue","body":"Description","comments":["human comment"]}' ]
}

@test "get_pr_for_issue finds an open AI branch for the issue" {
  export GH_STUB_PR_LINES=$'18 ai/issue-41-other\n19 ai/issue-42-feature'
  run_function shared.sh "get_pr_for_issue"
  [ "$status" -eq 0 ]
  [ "$output" = "19" ]
  grep -F -- "headRefName" "$GH_STUB_LOG"
}
