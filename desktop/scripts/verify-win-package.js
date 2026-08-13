// Fails the Windows build if native runtimes are missing or were packaged in a
// location the installed app will not use. This catches cross-build omissions
// before an installer reaches a Windows tester.
const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const resources = path.join(projectRoot, 'dist-electron', 'win-unpacked', 'resources');
const requiredFiles = [
  path.join(resources, 'app.asar'),
  path.join(resources, '7zip', '7z.exe'),
  path.join(resources, '7zip', '7z.dll'),
  path.join(resources, 'exiftool', 'exiftool.exe'),
  path.join(resources, 'exiftool', 'exiftool_files', 'perl.exe'),
  path.join(resources, 'exiftool', 'exiftool_files', 'exiftool.pl'),
  path.join(resources, 'app.asar.unpacked', 'electron', 'services', 'visual-hash.js'),
  path.join(resources, 'app.asar.unpacked', 'electron', 'services', 'visual-hash-worker.js'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'libheif-js', 'LICENSE'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'libheif-js', 'libheif-wasm', 'libheif.wasm'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'heic-decode', 'index.js'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'jpeg-js', 'index.js'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'pngjs', 'lib', 'png.js'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'pako', 'index.js'),
  path.join(resources, 'app.asar.unpacked', 'node_modules', 'utif2', 'UTIF.js'),
];

for (const filePath of requiredFiles) {
  if (!fs.existsSync(filePath)) throw new Error(`Windows package is missing ${path.relative(projectRoot, filePath)}`);
}

const unpackedRoot = path.join(resources, 'app.asar.unpacked');
const pakoFromUtif = require.resolve('pako', {
  paths: [path.join(unpackedRoot, 'node_modules', 'utif2')],
});
if (!pakoFromUtif.startsWith(unpackedRoot)) {
  throw new Error('Packaged UTIF decoder cannot resolve its unpacked pako dependency');
}

for (const filePath of [
  path.join(resources, '7zip', '7z.exe'),
  path.join(resources, 'exiftool', 'exiftool.exe'),
  path.join(resources, 'exiftool', 'exiftool_files', 'perl.exe'),
]) {
  if (fs.readFileSync(filePath).subarray(0, 2).toString('ascii') !== 'MZ') {
    throw new Error(`${path.relative(projectRoot, filePath)} is not a Windows PE executable`);
  }
}

const exiftoolFiles = fs.readdirSync(path.join(resources, 'exiftool', 'exiftool_files'), { recursive: true });
if (exiftoolFiles.length < 500) throw new Error('Packaged Windows ExifTool runtime is incomplete');

console.log('Verified Windows package: native runtimes and unpacked Smart Duplicates decoders are complete.');
