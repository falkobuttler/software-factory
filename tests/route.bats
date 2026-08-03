#!/usr/bin/env bats

load helpers

setup() {
  setup_shell_test
  export EVENT_ACTION="created"
  export LABEL_NAME=""
  export EVENT_PR_NUMBER=""
}

route() {
  export EVENT_NAME EVENT_ACTION LABEL_NAME EVENT_PR_NUMBER GH_STUB_LABELS
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/route.sh'"
}

assert_action() {
  [ "$status" -eq 0 ]
  grep -Fx "action=$1" "$GITHUB_OUTPUT"
}

@test "issues labeled with a non-trigger label is a noop" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=bug GH_STUB_LABELS="" route
  assert_action noop
}

@test "new labeled issue starts planning" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=ai-factory GH_STUB_LABELS="" route
  assert_action plan
}

@test "questioning labeled issue resumes planning" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=ai-factory GH_STUB_LABELS=ai:questioning route
  assert_action resume-plan
}

@test "implementing or stuck labeled issue starts implementation" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=ai-factory GH_STUB_LABELS=ai:implementing route
  assert_action implement
  : > "$GITHUB_OUTPUT"
  GH_STUB_LABELS=ai:stuck route
  assert_action implement
}

@test "reviewing or addressing-review labeled issue starts review" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=ai-factory GH_STUB_LABELS=ai:reviewing route
  assert_action review
  : > "$GITHUB_OUTPUT"
  GH_STUB_LABELS=ai:addressing-review route
  assert_action review
}

@test "done labeled issue is a noop" {
  EVENT_NAME=issues EVENT_ACTION=labeled LABEL_NAME=ai-factory GH_STUB_LABELS=ai:done route
  assert_action noop
}

@test "issue comment in questioning resumes planning" {
  EVENT_NAME=issue_comment EVENT_ACTION=created GH_STUB_LABELS=ai:questioning route
  assert_action resume-plan
}

@test "issue comment in stuck resumes implementation" {
  EVENT_NAME=issue_comment EVENT_ACTION=created GH_STUB_LABELS=ai:stuck route
  assert_action implement
}

@test "issue comment on a PR addresses PR feedback" {
  EVENT_NAME=issue_comment EVENT_ACTION=created GH_STUB_LABELS=ai:done EVENT_PR_NUMBER=19 route
  assert_action address-pr-feedback
}

@test "submitted pull request reviews address PR feedback" {
  EVENT_NAME=pull_request_review EVENT_ACTION=submitted GH_STUB_LABELS=ai:reviewing route
  assert_action address-pr-feedback
}

@test "unknown event is a noop" {
  EVENT_NAME=workflow_dispatch EVENT_ACTION=created GH_STUB_LABELS="" route
  assert_action noop
}
