#!/usr/bin/env node
// Streaming wrapper for @anthropic-ai/claude-agent-sdk.
// Prints Claude's text tokens as they arrive AND logs each tool call
// so CI logs show activity during long-running tools (e.g. xcodebuild).

import { query } from '@anthropic-ai/claude-agent-sdk';
import { readFileSync, writeFileSync } from 'fs';

const [, , promptFile, maxTurnsStr = '500'] = process.argv;
const outputFile = process.env.CLAUDE_OUTPUT_FILE || '/tmp/last-claude-output.txt';

if (!promptFile) {
  process.stderr.write('Usage: run-claude.mjs <prompt-file> [max-turns]\n');
  process.exit(1);
}

const prompt = readFileSync(promptFile, 'utf-8');
const maxTurns = parseInt(maxTurnsStr, 10);

function toolSummary(name, input) {
  switch (name) {
    case 'Bash':   return (input.command  || '').split('\n')[0].slice(0, 200);
    case 'Read':   return input.file_path || '';
    case 'Write':  return input.file_path || '';
    case 'Edit':   return input.file_path || '';
    case 'Glob':   return `${input.pattern || ''}${input.path ? ' in ' + input.path : ''}`;
    case 'Grep':   return `${input.pattern || ''} in ${input.path || '.'}`;
    case 'LS':     return input.path || '.';
    default:       return JSON.stringify(input).slice(0, 120);
  }
}

let fullOutput = '';
let exitCode = 0;
let currentTool = null;
let currentInput = '';

try {
  for await (const message of query({
    prompt,
    options: {
      includePartialMessages: true,
      allowedTools: ['Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep', 'LS'],
      maxTurns,
    },
  })) {
    if (message.type === 'stream_event') {
      const { event } = message;

      if (event.type === 'content_block_start') {
        const block = event.content_block;
        if (block?.type === 'tool_use') {
          currentTool = block.name;
          currentInput = '';
        }

      } else if (event.type === 'input_json_delta') {
        currentInput += event.delta?.partial_json || '';

      } else if (event.type === 'content_block_stop') {
        if (currentTool) {
          let parsed = {};
          try { parsed = JSON.parse(currentInput); } catch { /* partial json */ }
          const summary = toolSummary(currentTool, parsed);
          process.stdout.write(`\n[${currentTool}] ${summary}\n`);
          currentTool = null;
          currentInput = '';
        }

      } else if (event.type === 'content_block_delta') {
        if (event.delta?.type === 'text_delta') {
          const text = event.delta.text;
          process.stdout.write(text);
          fullOutput += text;
        }
      }

    } else if (message.type === 'result') {
      if (message.subtype !== 'success') {
        process.stderr.write(`[run-claude] Agent ended with subtype: ${message.subtype}\n`);
        exitCode = 1;
      }
    }
  }
} catch (err) {
  process.stderr.write(`[run-claude] Error: ${err.message}\n`);
  exitCode = 1;
}

writeFileSync(outputFile, fullOutput);
process.exit(exitCode);
