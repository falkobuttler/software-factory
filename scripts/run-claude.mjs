#!/usr/bin/env node
/**
 * Streaming Claude Code agent runner.
 * Reads prompt from stdin, streams output live to stdout as the agent works.
 *
 * Env vars:
 *   ANTHROPIC_API_KEY     - required
 *   WORK_DIR              - working directory for the agent (defaults to cwd)
 *   CLAUDE_MAX_TURNS      - max agent turns (default: 50)
 *   CLAUDE_ALLOWED_TOOLS  - comma-separated tool list (default: Bash,Read,Write,Edit,Glob,Grep,LS)
 *
 * Exit code: 0 on success, 1 on failure.
 */

import { query } from '@anthropic-ai/claude-code';
import { readFileSync } from 'fs';

const prompt = readFileSync('/dev/stdin', 'utf8').trim();
if (!prompt) {
  console.error('[run-claude] Error: empty prompt received on stdin');
  process.exit(1);
}

const maxTurns = parseInt(process.env.CLAUDE_MAX_TURNS ?? '50', 10);
const allowedTools = (process.env.CLAUDE_ALLOWED_TOOLS ?? 'Bash,Read,Write,Edit,Glob,Grep,LS')
  .split(',').map(t => t.trim());
const cwd = process.env.WORK_DIR ?? process.cwd();

let succeeded = false;

try {
  for await (const message of query({
    prompt,
    options: {
      maxTurns,
      allowedTools,
      permissionMode: 'acceptEdits',
      cwd,
    },
  })) {
    switch (message.type) {
      case 'assistant': {
        for (const block of message.message?.content ?? []) {
          if (block.type === 'text' && block.text) {
            process.stdout.write(block.text);
          } else if (block.type === 'tool_use') {
            const raw = JSON.stringify(block.input ?? {});
            const preview = raw.length > 300 ? raw.slice(0, 300) + '…' : raw;
            process.stdout.write(`\n[tool:${block.name}] ${preview}\n`);
          }
        }
        break;
      }
      case 'result': {
        if (message.subtype === 'success') {
          succeeded = true;
          // result field holds the final assistant turn text if any
          if (message.result) process.stdout.write('\n' + message.result);
        } else {
          console.error(`\n[run-claude] Agent did not succeed: ${message.subtype}`);
        }
        break;
      }
      // 'system' (init) and 'user' messages are informational — ignore
    }
  }
} catch (err) {
  console.error(`[run-claude] Fatal error: ${err.message}`);
  process.exit(1);
}

process.exit(succeeded ? 0 : 1);
