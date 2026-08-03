setup_shell_test() {
  TEST_TMP="$BATS_TEST_TMPDIR/factory"
  mkdir -p "$TEST_TMP/bin"
  cp "$BATS_TEST_DIRNAME/fixtures/gh" "$TEST_TMP/bin/gh"
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
  export GH_STUB_LOG="$TEST_TMP/gh.log"
  : > "$GH_STUB_LOG"
  export TARGET_REPO="example/repo"
  export ISSUE_NUMBER="42"
  export GITHUB_OUTPUT="$TEST_TMP/github-output"
  : > "$GITHUB_OUTPUT"
}

run_function() {
  run bash -c "source '$BATS_TEST_DIRNAME/../scripts/$1'; $2"
}
