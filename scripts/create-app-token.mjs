#!/usr/bin/env node
import { createSign } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

export async function createAppToken({ appId, privateKey, repository, fetchImpl = fetch }) {
  if (!appId || !privateKey || !repository) {
    throw new Error('APP_ID, APP_PRIVATE_KEY, and TARGET_REPO are required');
  }

  const now = Math.floor(Date.now() / 1000);
  const unsignedJwt = `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode({
    iat: now - 60,
    exp: now + 9 * 60,
    iss: appId,
  })}`;
  const signer = createSign('RSA-SHA256');
  signer.update(unsignedJwt);
  signer.end();
  const jwt = `${unsignedJwt}.${signer.sign(privateKey.replace(/\\n/g, '\n'), 'base64url')}`;

  const headers = {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${jwt}`,
    'User-Agent': 'software-factory',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  const github = async (path, options = {}) => {
    const response = await fetchImpl(`https://api.github.com${path}`, {
      ...options,
      headers: { ...headers, ...options.headers },
    });
    if (!response.ok) {
      const body = await response.text();
      throw new Error(`GitHub API ${response.status} ${response.statusText}: ${body}`);
    }
    return response.json();
  };

  const installation = await github(`/repos/${repository}/installation`);
  const repositoryName = repository.slice(repository.indexOf('/') + 1);
  const access = await github(`/app/installations/${installation.id}/access_tokens`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ repositories: [repositoryName] }),
  });
  return access.token;
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  try {
    const token = await createAppToken({
      appId: process.env.APP_ID,
      privateKey: process.env.APP_PRIVATE_KEY,
      repository: process.env.TARGET_REPO,
    });
    process.stdout.write(token);
  } catch (error) {
    console.error(`Unable to refresh GitHub App token: ${error.message}`);
    process.exit(1);
  }
}
