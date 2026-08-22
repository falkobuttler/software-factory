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

A separate scheduled automation triages issues before anyone decides to implement them:

```
schedule (nightly) / workflow_dispatch
        │
        ▼
   triage.sh   for each open issue without ai-triaged / ai-factory
        │       → type + size labels, summary + blocking questions comment
        ▼
   ai-triaged (issue is never triaged twice)
```

Triage is read-only — it never branches, commits, or opens PRs, and it does not
touch `ai:*` state labels.

State is tracked via `ai:*` labels on the issue. Re-adding `ai-factory` resumes from the current state. The agent posts questions to the issue thread if it needs clarification, and marks itself stuck if it hits a blocker.

## Repository structure

```
.github/workflows/
  dispatcher.yml          # Reusable workflow called by every target repo
  triage.yml              # Reusable scheduled triage workflow

action.yml                # Exposes the factory runtime outside the target worktree

scripts/
  triage.sh               # Triage agent: classifies untriaged open issues
  route.sh                # Reads event + issue state → picks pipeline action
  plan.sh                 # Planning agent: produces structured plan or asks questions
  implement.sh            # Implementation agent: branch, code, commit, open PR
  review-cycle.sh         # Review loop: AI review → address feedback → repeat
  address-pr-feedback.sh  # Handles human comments/reviews on the PR
  state.sh                # get_state / set_state via GitHub issue labels
  shared.sh               # Shared utilities: run_claude, post_comment, helpers

scripts/run-claude.mjs    # Node.js streaming wrapper for @anthropic-ai/claude-agent-sdk

prompts/
  triager.md              # System prompt for the triage agent
  planner.md              # System prompt for the planning agent
  implementer.md          # System prompt for the implementation agent
  reviewer.md             # System prompt for the code review agent

target-repo-template/
  .github/workflows/
    software-factory.yml         # Thin trigger file to copy into target repos
    software-factory-triage.yml  # Optional nightly triage schedule
```

## Setting up a new target repo

1. Copy `target-repo-template/.github/workflows/software-factory.yml` into the target repo's `.github/workflows/`.
2. Set these secrets on the target repo (or at org level):
   - `APP_ID` — GitHub App ID
   - `APP_PRIVATE_KEY` — GitHub App private key (PEM)
   - `ANTHROPIC_API_KEY` — Anthropic API key
3. Create a `CLAUDE.md` in the target repo root describing the tech stack, project conventions, and test commands (e.g. `npm test`, `xcodebuild test ...`). The agents read this on every run.
4. Add the `ai-factory` label to any issue to trigger the pipeline.
5. Optionally copy `target-repo-template/.github/workflows/software-factory-triage.yml` as well to get nightly issue triage.

For repos that need a specific runner (e.g. macOS + Xcode for iOS), pass `runner: self-hosted` in the workflow's `with:` block. Git fetches and pushes on self-hosted runners use local SSH authentication rather than the short-lived GitHub App checkout token; `gh` API commands use App tokens that are renewed around long-running agent calls.

## Trigger events

| Event | Condition | Action |
|---|---|---|
| `issues: labeled` | Label is `ai-factory` | Resume from current state |
| `issue_comment: created` | Human comment, issue open, state is `questioning` | Resume planning |
| `issue_comment: created` | Human comment, issue open, state is `stuck` | Resume implementation |
| `issue_comment: created` | Human comment on a PR | Address PR feedback |
| `pull_request_review: submitted` | Human review | Address PR feedback |
| `schedule` / `workflow_dispatch` | Triage workflow | Triage untriaged open issues |

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

Triage labels are deliberately outside the `ai:` namespace so `set_state` does not clear them:

| Label | Meaning |
|---|---|
| `ai-triaged` | Issue has been triaged; excluded from future triage runs |
| `size:XS`…`size:XL` | Implementation effort estimated by the triage agent |
| `bug` / `enhancement` / `documentation` / `question` / `chore` | Issue type chosen by the triage agent |

## Scripts

### `scripts/run-claude.mjs`

Streaming wrapper for `@anthropic-ai/claude-agent-sdk`. Replaces `claude --print` to get real-time output in CI logs. Reads a prompt file, streams token deltas to stdout, captures full output to `CLAUDE_OUTPUT_FILE`.

```bash
node scripts/run-claude.mjs <prompt-file> [max-turns]
```

### `scripts/shared.sh`

Source this in every script. Key functions:

- `run_claude <prompt-file> [max-turns]` — runs the agent, streams output
- `DEFAULT_AGENT_MAX_TURNS` — default turn limit for agents (`500`)
- `REVIEW_AGENT_MAX_TURNS` — review-agent turn limit (`100`)
- `TRIAGE_AGENT_MAX_TURNS` — triage-agent turn limit (`40`)
- `post_comment <body>` — posts a bot-tagged comment on `$ISSUE_NUMBER`
- `post_pr_comment <pr> <body>` — posts a bot-tagged comment on a PR
- `get_plan_from_issue` — extracts the plan block from issue comments
- `get_pr_for_issue` — finds the open AI-created PR for `$ISSUE_NUMBER`
- `list_untriaged_issues [limit]` — open issues without `ai-triaged` / `ai-factory`, oldest first
- `triage_field <block> <name>` / `triage_questions <block>` — parse the agent's `TRIAGE:` block
- `is_valid_triage_type` / `is_valid_triage_size` — reject classifications outside the allowed sets
- `apply_triage_labels <type> <size>` / `mark_triaged` — write the triage result back to the issue

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
| `TRIAGE:` | triager | Start of the classification block (`Type`, `Size`, `Area`, `Summary`, `Questions`) |

## Dependencies

- `@anthropic-ai/claude-agent-sdk` — declared in `package.json`, installed into the downloaded factory action directory by the dispatcher
- `gh` CLI — must be available on the runner (pre-installed on GitHub-hosted runners and most self-hosted setups)
- `git`, `bash`, `node` (v20+), `sed`, `jq` (via `gh`'s bundled jq)

## Modifying prompts

Prompts live in `prompts/`. Changes take effect on the next pipeline run (the dispatcher downloads the factory action from `main`). The reviewer prompt (`prompts/reviewer.md`) uses severity levels CRITICAL/HIGH/MEDIUM/LOW; only Critical or High findings block approval.
