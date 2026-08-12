// Downloads and verifies the official 7-Zip runtime bundled with Foldiq for Windows.
// The version and SHA-256 are pinned so CI cannot silently package a different binary.
const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { path7za } = require('7zip-bin');

const VERSION = '26.02';
const DOWNLOAD_URL = `https://github.com/ip7z/7zip/releases/download/${VERSION}/7z2602-x64.exe`;
const EXPECTED_SHA256 = '6745fa76dc2ea031596d8678f6f6b99c3c1b435b4164a63485adbbc7b8d82ef0';
const outputDirectory = path.resolve(__dirname, '..', '.vendor', '7zip-win');
const requiredFiles = ['7z.exe', '7z.dll', 'License.txt'];

function download(url, destination, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': 'Foldiq-build' } }, response => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume();
        if (redirectsLeft === 0) return reject(new Error('Too many download redirects'));
        return download(new URL(response.headers.location, url).toString(), destination, redirectsLeft - 1)
          .then(resolve, reject);
      }
      if (response.statusCode !== 200) {
        response.resume();
        return reject(new Error(`7-Zip download failed with HTTP ${response.statusCode}`));
      }
      const file = fs.createWriteStream(destination, { flags: 'wx' });
      response.pipe(file);
      file.on('finish', () => file.close(resolve));
      file.on('error', reject);
    });
    request.on('error', reject);
  });
}

function sha256(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

async function main() {
  if (requiredFiles.every(file => fs.existsSync(path.join(outputDirectory, file)))) return;

  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-7zip-build-'));
  const installerPath = path.join(temporaryDirectory, '7zip-x64.exe');
  const extractedDirectory = path.join(temporaryDirectory, 'extracted');

  try {
    await download(DOWNLOAD_URL, installerPath);
    const actualSha256 = sha256(installerPath);
    if (actualSha256 !== EXPECTED_SHA256) {
      throw new Error(`7-Zip checksum mismatch: expected ${EXPECTED_SHA256}, got ${actualSha256}`);
    }

    if (process.platform !== 'win32') fs.chmodSync(path7za, 0o755);
    fs.mkdirSync(extractedDirectory, { recursive: true });
    execFileSync(path7za, [
      'e', '-y', `-o${extractedDirectory}`, installerPath, ...requiredFiles,
    ], { stdio: 'ignore', windowsHide: true });

    for (const file of requiredFiles) {
      if (!fs.existsSync(path.join(extractedDirectory, file))) {
        throw new Error(`Official 7-Zip package did not contain ${file}`);
      }
    }

    fs.mkdirSync(path.dirname(outputDirectory), { recursive: true });
    fs.renameSync(extractedDirectory, outputDirectory);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(`Unable to prepare the verified 7-Zip runtime: ${error.message}`);
  process.exitCode = 1;
});
