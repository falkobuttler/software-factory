# Software Factory

An autonomous AI agent pipeline for GitHub. Assign an issue to the bot and it plans, implements, reviews, and hands off a PR — completely hands-off.

## How it works

```
1. Assign issue to bot
        ↓
2. Agent reads the repo and plans the work
   (asks questions in issue comments if ambiguous)
        ↓
3. Agent implements on a new branch
   (posts a stuck comment and waits if it hits a blocker)
        ↓
4. Agent opens a draft PR
        ↓
5. AI reviewer checks the PR (up to 3 rounds)
        ↓
6. PR marked ready for human review
```

## Setup

### 1. Create a GitHub App

Go to **GitHub Settings → Developer settings → GitHub Apps → New GitHub App**.

| Setting | Value |
|---|---|
| GitHub App name | `your-factory-name` |
| Homepage URL | URL of this repo |
| Webhook | Disabled |
| **Repository permissions** | |
| → Contents | Read & write |
| → Issues | Read & write |
| → Pull requests | Read & write |
| → Metadata | Read-only |

After creating the app:
- Note the **App ID** (shown on the app settings page)
- Generate a **private key** (scroll down → "Generate a private key") and save the `.pem` file
- Note the **bot login** shown on the app page — it looks like `your-factory-name[bot]`

### 2. Install the App on your repositories

From the GitHub App settings page → **Install App** → select the organization or specific repos.

Install it on:
- This factory repo (`software-factory`)
- Every target repo you want the factory to manage

### 3. Configure secrets

Add the following secrets. You can add them at the **organization level** (recommended, so all repos inherit them) or per-repo.

| Secret | Value |
|---|---|
| `APP_ID` | The App ID from step 1 |
| `APP_PRIVATE_KEY` | The full contents of the `.pem` private key file |
| `ANTHROPIC_API_KEY` | Your Anthropic API key from console.anthropic.com |

### 4. Onboard a target repo

For each repo you want the factory to manage:

**a)** Copy the template workflow into the repo:
```bash
mkdir -p .github/workflows
cp path/to/software-factory/target-repo-template/.github/workflows/software-factory.yml \
   .github/workflows/software-factory.yml
```

**b)** Edit the copied file and replace:
- `YOUR_ORG/software-factory` → the actual path to this factory repo (e.g. `acme/software-factory`)
- `your-app-name[bot]` → your GitHub App's bot login (e.g. `acme-factory[bot]`)

**c)** Commit and push the workflow file.

**d)** Create a `CLAUDE.md` in the target repo root describing the codebase:
```markdown
# Project conventions

## Tech stack
- Language: TypeScript
- Runtime: Node.js 20
- Framework: Express

## Test command
npm test

## Lint command
npm run lint

## Key conventions
- Use `src/` for source files
- All exports from `src/index.ts`
- Tests in `__tests__/` alongside source files
```

For repositories that run on a self-hosted machine, pass `runner: self-hosted`
in the workflow's `with:` block. Git fetches and pushes use that runner's SSH
authentication, so long-running jobs do not depend on the one-hour App token
stored by checkout. The `gh` CLI continues to use the App token for GitHub API
operations; the factory renews that token before each stage and after every
long-running agent call. GitHub-hosted jobs retain the checkout token because
those runners have no durable local Git authentication. The target repository
is checked out at the job workspace root. The factory runtime is downloaded as
a GitHub Action under the runner's `_actions` directory, so it does not require
a second checkout or appear inside the target worktree.

### 5. Use the factory

Add the **`ai-factory`** label to any issue. The pipeline starts automatically.

#### Labels used
| Label | Meaning |
|---|---|
| `ai-factory` | Trigger label — add this to start the pipeline |
| `ai:planning` | Agent is planning the work |
| `ai:questioning` | Agent has questions; waiting for answers |
| `ai:implementing` | Agent is writing code |
| `ai:reviewing` | AI review in progress |
| `ai:addressing-review` | Agent is addressing review feedback |
| `ai:stuck` | Agent is stuck; needs human help |
| `ai:done` | PR is ready for human review |

#### Q&A loop
If the issue is ambiguous, the agent posts clarifying questions as an issue comment. Reply in the comments and the pipeline resumes automatically.

#### Stuck loop
If the agent can't resolve test failures or a technical blocker, it posts a detailed explanation. Reply with guidance and the pipeline resumes.

## Repository structure

```
software-factory/
├── action.yml                         # Makes the runtime available without a checkout
├── .github/
│   └── workflows/
│       └── dispatcher.yml          # Main reusable workflow (called by target repos)
├── prompts/
│   ├── planner.md                  # System prompt for the planning agent
│   ├── implementer.md              # System prompt for the implementation agent
│   └── reviewer.md                 # System prompt for the review agent
├── scripts/
│   ├── route.sh                    # Chooses the stage for the current event/state
│   ├── plan.sh                     # Planning stage
│   ├── implement.sh                # Implementation stage
│   ├── review-cycle.sh             # Automated review and feedback loop
│   ├── address-pr-feedback.sh      # Handles human PR feedback
│   ├── shared.sh                   # Shared agent and GitHub helpers
│   ├── state.sh                    # GitHub label state management
│   └── run-claude.mjs              # Streaming Claude Agent SDK wrapper
└── target-repo-template/
    └── .github/
        └── workflows/
            └── software-factory.yml  # Copy this into each target repo
```

## Customizing agent behavior

Edit the files in `prompts/` to change how each agent thinks:
- **`prompts/planner.md`** — how the agent plans work, what questions to ask
- **`prompts/implementer.md`** — coding standards, when to give up, output format
- **`prompts/reviewer.md`** — review criteria, what counts as a blocking issue

Changes to prompts take effect on the next pipeline run because the dispatcher
downloads the factory action from `@main`. For a versioned release, pin both the
target workflow's dispatcher reference and the action reference inside the
dispatcher.

## Cost and runtime estimates

| Task complexity | Estimated time | Estimated API cost |
|---|---|---|
| Simple bug fix | 5–15 min | $0.50–$2 |
| New feature (small) | 15–45 min | $2–$8 |
| New feature (medium) | 45–120 min | $8–$25 |

Costs depend on repo size (context length) and number of review rounds.

## Limitations

- Maximum 6 hours per GitHub Actions job (sufficient for most tasks)
- The agent works best when `CLAUDE.md` clearly documents test commands and conventions
- Complex architectural changes may require human guidance via the stuck-comment loop
- The agent does not create migration scripts or handle database schema changes automatically
