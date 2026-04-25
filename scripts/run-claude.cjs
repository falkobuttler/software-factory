#!/usr/bin/env node
'use strict';
/**
 * Streaming Claude Code agent runner (CommonJS).
 * Reads prompt from stdin, streams output live to stdout as the agent works.
 *
 * Env vars:
 *   ANTHROPIC_API_KEY     - required
 *   WORK_DIR              - working directory for the agent
 *   CLAUDE_MAX_TURNS      - max agent turns (default: 500)
 *   CLAUDE_ALLOWED_TOOLS  - comma-separated tool list
 */

async function main() {
  // Verify the package exports what we need before doing anything else
  let query;
  try {
    ({ query } = require('@anthropic-ai/claude-code'));
  } catch (err) {
    console.error(`[run-claude] Failed to load @anthropic-ai/claude-code: ${err.message}`);
    console.error('[run-claude] NODE_PATH:', process.env.NODE_PATH);
    process.exit(1);
  }

  if (typeof query !== 'function') {
    console.error(`[run-claude] @anthropic-ai/claude-code does not export a 'query' function.`);
    console.error('[run-claude] Exported keys:', Object.keys(require('@anthropic-ai/claude-code')).join(', '));
    process.exit(1);
  }

  const chunks = [];
  process.stdin.on('data', d => chunks.push(d));
  await new Promise(resolve => process.stdin.on('end', resolve));
  const prompt = Buffer.concat(chunks).toString('utf8').trim();

  if (!prompt) {
    console.error('[run-claude] Error: empty prompt received on stdin');
    process.exit(1);
  }

  const maxTurns = parseInt(process.env.CLAUDE_MAX_TURNS ?? '500', 10);
  const allowedTools = (process.env.CLAUDE_ALLOWED_TOOLS ?? 'Bash,Read,Write,Edit,Glob,Grep,LS')
    .split(',').map(t => t.trim());
  const cwd = process.env.WORK_DIR ?? process.cwd();

  let succeeded = false;

  for await (const message of query({
    prompt,
    options: { maxTurns, allowedTools, permissionMode: 'acceptEdits', cwd },
  })) {
    switch (message.type) {
      case 'assistant':
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
      case 'result':
        if (message.subtype === 'success') {
          succeeded = true;
          if (message.result) process.stdout.write('\n' + message.result);
        } else {
          console.error(`\n[run-claude] Agent did not succeed: ${message.subtype}`);
        }
        break;
    }
  }

  process.exit(succeeded ? 0 : 1);
}

main().catch(err => {
  console.error(`[run-claude] Fatal error: ${err.message}`);
  process.exit(1);
});
