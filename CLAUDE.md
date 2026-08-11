# Software Factory

An autonomous GitHub issue-to-PR pipeline powered by Claude Code. Adding the `ai-factory` label to an issue triggers the agent to plan, implement, review, and iterate — entirely hands-off.

## How it works

```
issues/labeled (ai-factory)
        │
        ▼
   route.sh  ──────────────────────────────────────────────┐
        │                                                   │
   ┌────┴────┐                                              │
   │  plan   │  asks questions if ambiguous, posts plan     │
   └────┬────┘                                              │
        │                                                   │
   ┌────┴──────────┐                                        │
   │  implement    │  creates branch, writes code, opens PR │
   └────┬──────────┘                                        │
        │                                                   │
   ┌────┴──────────┐   up to 3 rounds                       │
   │ review-cycle  │  AI reviews → addresses → re-reviews   │
   └────┬──────────┘                                        │
        │                                                   │
   PR marked ready for human review                         │
                                                            │
   Human comments on PR ──────────────────────────────────►─┘
   (address-pr-feedback → review-cycle)
```

State is tracked via `ai:*` labels on the issue. Re-adding `ai-factory` resumes from the current state. The agent posts questions to the issue thread if it needs clarification, and marks itself stuck if it hits a blocker.

## Repository structure

```
.github/workflows/
  dispatcher.yml          # Reusable workflow called by every target repo

action.yml                # Exposes the factory runtime outside the target worktree

scripts/
  route.sh                # Reads event + issue state → picks pipeline action
  plan.sh                 # Planning agent: produces structured plan or asks questions
  implement.sh            # Implementation agent: branch, code, commit, open PR
  review-cycle.sh         # Review loop: AI review → address feedback → repeat
  address-pr-feedback.sh  # Handles human comments/reviews on the PR
  state.sh                # get_state / set_state via GitHub issue labels
  shared.sh               # Shared utilities: run_claude, post_comment, helpers

scripts/run-claude.mjs    # Node.js streaming wrapper for @anthropic-ai/claude-agent-sdk

prompts/
  planner.md              # System prompt for the planning agent
  implementer.md          # System prompt for the implementation agent
  reviewer.md             # System prompt for the code review agent

target-repo-template/
  .github/workflows/
    software-factory.yml  # Thin trigger file to copy into target repos
```

## Setting up a new target repo

1. Copy `target-repo-template/.github/workflows/software-factory.yml` into the target repo's `.github/workflows/`.
2. Set these secrets on the target repo (or at org level):
   - `APP_ID` — GitHub App ID
   - `APP_PRIVATE_KEY` — GitHub App private key (PEM)
   - `ANTHROPIC_API_KEY` — Anthropic API key
3. Create a `CLAUDE.md` in the target repo root describing the tech stack, project conventions, and test commands (e.g. `npm test`, `xcodebuild test ...`). The agents read this on every run.
4. Add the `ai-factory` label to any issue to trigger the pipeline.

For repos that need a specific runner (e.g. macOS + Xcode for iOS), pass `runner: self-hosted` in the workflow's `with:` block. Git fetches and pushes on self-hosted runners use local SSH authentication rather than the short-lived GitHub App checkout token; `gh` API commands continue to use the App token.

## Trigger events

| Event | Condition | Action |
|---|---|---|
| `issues: labeled` | Label is `ai-factory` | Resume from current state |
| `issue_comment: created` | Human comment, issue open, state is `questioning` | Resume planning |
| `issue_comment: created` | Human comment, issue open, state is `stuck` | Resume implementation |
| `issue_comment: created` | Human comment on a PR | Address PR feedback |
| `pull_request_review: submitted` | Human review | Address PR feedback |

## Issue state machine

Labels on the issue track where the pipeline is:

| Label | Meaning |
|---|---|
| `ai:planning` | Planner is running |
| `ai:questioning` | Agent posted questions, waiting for answers |
| `ai:implementing` | Implementer is running |
| `ai:reviewing` | Reviewer is running |
| `ai:addressing-review` | Agent is addressing review feedback |
| `ai:stuck` | Agent hit a blocker, waiting for human guidance |
| `ai:done` | Pipeline complete, PR is ready for human review |

## Scripts

### `scripts/run-claude.mjs`

Streaming wrapper for `@anthropic-ai/claude-agent-sdk`. Replaces `claude --print` to get real-time output in CI logs. Reads a prompt file, streams token deltas to stdout, captures full output to `CLAUDE_OUTPUT_FILE`.

```bash
node scripts/run-claude.mjs <prompt-file> [max-turns]
```

### `scripts/shared.sh`

Source this in every script. Key functions:

- `run_claude <prompt-file> [max-turns]` — runs the agent, streams output
- `post_comment <body>` — posts a bot-tagged comment on `$ISSUE_NUMBER`
- `post_pr_comment <pr> <body>` — posts a bot-tagged comment on a PR
- `get_plan_from_issue` — extracts the plan block from issue comments
- `get_pr_for_issue` — finds the open AI-created PR for `$ISSUE_NUMBER`

### `scripts/state.sh`

- `get_state` — reads current `ai:*` label from the issue, returns the state name (e.g. `implementing`)
- `set_state <name>` — removes all `ai:*` labels and adds `ai:<name>`

## Agent output markers

The pipeline uses plain-text markers in Claude's output to drive control flow:

| Marker | Script | Meaning |
|---|---|---|
| `PLAN:` | planner | Start of the implementation plan |
| `QUESTIONS:` | planner | Agent has questions before planning |
| `DONE:` | implementer | Implementation finished, tests pass |
| `STUCK:` | implementer | Agent is blocked, needs human help |
| `LGTM` | reviewer | PR approved, no Critical/High findings |
| `CHANGES_REQUESTED:` | reviewer | PR has findings that must be fixed |

## Dependencies

- `@anthropic-ai/claude-agent-sdk` — declared in `package.json`, installed into the downloaded factory action directory by the dispatcher
- `gh` CLI — must be available on the runner (pre-installed on GitHub-hosted runners and most self-hosted setups)
- `git`, `bash`, `node` (v20+), `sed`, `jq` (via `gh`'s bundled jq)

## Modifying prompts

Prompts live in `prompts/`. Changes take effect on the next pipeline run (the dispatcher downloads the factory action from `main`). The reviewer prompt (`prompts/reviewer.md`) uses severity levels CRITICAL/HIGH/MEDIUM/LOW; only Critical or High findings block approval.
