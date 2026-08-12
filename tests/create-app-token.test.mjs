import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';
import { createAppToken } from '../scripts/create-app-token.mjs';

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });

test('creates a repository-scoped installation token', async () => {
  const requests = [];
  const responses = [
    { id: 1234 },
    { token: 'fresh-installation-token' },
  ];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    const body = responses.shift();
    return {
      ok: true,
      json: async () => body,
    };
  };

  const token = await createAppToken({
    appId: '9876',
    privateKey: pem,
    repository: 'example/project',
    fetchImpl,
  });

  assert.equal(token, 'fresh-installation-token');
  assert.equal(requests[0].url, 'https://api.github.com/repos/example/project/installation');
  assert.match(requests[0].options.headers.Authorization, /^Bearer [^.]+\.[^.]+\.[^.]+$/);
  assert.equal(requests[1].url, 'https://api.github.com/app/installations/1234/access_tokens');
  assert.equal(requests[1].options.method, 'POST');
  assert.deepEqual(JSON.parse(requests[1].options.body), { repositories: ['project'] });
});

test('reports GitHub API failures without exposing a token', async () => {
  const fetchImpl = async () => ({
    ok: false,
    status: 401,
    statusText: 'Unauthorized',
    text: async () => 'Bad credentials',
  });

  await assert.rejects(
    createAppToken({
      appId: '9876',
      privateKey: pem,
      repository: 'example/project',
      fetchImpl,
    }),
    /GitHub API 401 Unauthorized: Bad credentials/,
  );
});
