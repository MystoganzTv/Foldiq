const { parentPort } = require('worker_threads');
const { computeVisualHashes } = require('./visual-hash');

parentPort.on('message', async ({ id, filePath, knownWidth, knownHeight }) => {
  const hashes = await computeVisualHashes(filePath, knownWidth, knownHeight);
  parentPort.postMessage({ id, hashes });
});
