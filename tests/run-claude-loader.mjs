export async function resolve(specifier, context, nextResolve) {
  if (specifier === '@anthropic-ai/claude-agent-sdk') {
    return { url: 'data:text/javascript,' + encodeURIComponent(`
      export async function* query() {
        const scenario = process.env.MOCK_CLAUDE_SCENARIO || 'text';
        if (scenario === 'throw') throw new Error('mock failure');
        yield { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'hello ' } } };
        yield { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'world' } } };
        if (scenario === 'tool') {
          yield { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', name: 'Bash' } } };
          yield { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '{"command":"ls"}' } } };
          yield { type: 'stream_event', event: { type: 'content_block_stop' } };
        }
        if (scenario === 'failure') yield { type: 'result', subtype: 'error' };
        else yield { type: 'result', subtype: 'success' };
      }
    `), shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
