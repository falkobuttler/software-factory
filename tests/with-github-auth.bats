#!/usr/bin/env bats

auth_wrapper="$BATS_TEST_DIRNAME/../scripts/with-github-auth.sh"

@test "local mode removes workflow tokens before running the stage" {
  run env \
    GITHUB_AUTH_MODE=local \
    GH_TOKEN=expired-gh-token \
    GITHUB_TOKEN=expired-github-token \
    APP_GH_TOKEN=expired-app-token \
    bash "$auth_wrapper" bash -c \
      'test -z "${GH_TOKEN+x}" && test -z "${GITHUB_TOKEN+x}" && test -z "${APP_GH_TOKEN+x}"'

  [ "$status" -eq 0 ]
}

@test "app mode exposes only the App token as GH_TOKEN" {
  run env \
    GITHUB_AUTH_MODE=app \
    APP_GH_TOKEN=app-token \
    bash "$auth_wrapper" bash -c \
      'test "$GH_TOKEN" = app-token && test -z "${APP_GH_TOKEN+x}"'

  [ "$status" -eq 0 ]
}

@test "app mode requires an App token" {
  run env GITHUB_AUTH_MODE=app bash "$auth_wrapper" true

  [ "$status" -ne 0 ]
  [[ "$output" == *"APP_GH_TOKEN is required in app auth mode"* ]]
}

@test "unknown authentication modes fail before running the stage" {
  run env GITHUB_AUTH_MODE=unknown bash "$auth_wrapper" true

  [ "$status" -eq 1 ]
  [ "$output" = "Unsupported GitHub authentication mode: unknown" ]
}
