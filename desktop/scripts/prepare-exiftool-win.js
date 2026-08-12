// Downloads and verifies the official Windows ExifTool runtime. npm omits this
// OS-specific optional package when a Windows installer is cross-built on macOS,
// so it must be staged explicitly instead of relying on node_modules.
const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const tar = require('tar');

const VERSION = '13.59.2';
const DOWNLOAD_URL = `https://registry.npmjs.org/exiftool-vendored.exe/-/exiftool-vendored.exe-${VERSION}.tgz`;
const EXPECTED_SHA256 = '4c135bfb89f5bf1f1bb7d7cead45dced3d89ffae17dccaf425cad69f62d11029';
const outputDirectory = path.resolve(__dirname, '..', '.vendor', 'exiftool-win');
const requiredFiles = [
  'exiftool.exe',
  path.join('exiftool_files', 'perl.exe'),
  path.join('exiftool_files', 'exiftool.pl'),
];

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
        return reject(new Error(`ExifTool download failed with HTTP ${response.statusCode}`));
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

function runtimeIsComplete(directory) {
  if (!requiredFiles.every(file => fs.existsSync(path.join(directory, file)))) return false;
  const executableHeader = fs.readFileSync(path.join(directory, 'exiftool.exe')).subarray(0, 2).toString('ascii');
  return executableHeader === 'MZ';
}

async function main() {
  if (runtimeIsComplete(outputDirectory)) return;

  fs.mkdirSync(path.dirname(outputDirectory), { recursive: true });
  const temporaryDirectory = fs.mkdtempSync(
    path.join(path.dirname(outputDirectory), '.foldiq-exiftool-build-')
  );
  const archivePath = path.join(temporaryDirectory, 'exiftool-win.tgz');
  const extractedDirectory = path.join(temporaryDirectory, 'extracted');

  try {
    await download(DOWNLOAD_URL, archivePath);
    const actualSha256 = sha256(archivePath);
    if (actualSha256 !== EXPECTED_SHA256) {
      throw new Error(`ExifTool checksum mismatch: expected ${EXPECTED_SHA256}, got ${actualSha256}`);
    }

    fs.mkdirSync(extractedDirectory, { recursive: true });
    await tar.x({
      file: archivePath,
      cwd: extractedDirectory,
      strip: 2,
      filter: entryPath => entryPath.startsWith('package/bin/'),
    });

    if (!runtimeIsComplete(extractedDirectory)) {
      throw new Error('Official Windows package did not contain a complete PE ExifTool runtime');
    }

    fs.rmSync(outputDirectory, { recursive: true, force: true });
    fs.renameSync(extractedDirectory, outputDirectory);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(`Unable to prepare the verified Windows ExifTool runtime: ${error.message}`);
  process.exitCode = 1;
});
