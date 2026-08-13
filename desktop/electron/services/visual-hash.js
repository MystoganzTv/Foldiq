// Lightweight, local-only perceptual hashing for Smart Duplicates.
//
// The decoder never uploads media. It samples a 9x8 luminance grid and creates
// an orientation-invariant dHash. Eight hashes are retained (rotations and
// mirrors) so converted files still match when EXIF orientation was flattened.

const fs = require('fs');
const path = require('path');
const { Worker } = require('worker_threads');
const jpeg = require('jpeg-js');
const { PNG } = require('pngjs');
const decodeHeic = require('heic-decode');
const UTIF = require('utif2');

const MAX_PIXEL_COUNT = 60_000_000;
const MAX_FILE_BYTES = 256 * 1024 * 1024;
const SUPPORTED_EXTENSIONS = new Set([
  '.jpg', '.jpeg', '.png', '.heic', '.heif', '.tif', '.tiff',
]);

function decodeWithElectron(filePath) {
  try {
    // Available in the packaged Electron main process. Unit tests run under
    // plain Node, where require('electron') resolves to an executable path.
    const { nativeImage } = require('electron');
    if (!nativeImage?.createFromPath) return null;
    const image = nativeImage.createFromPath(filePath);
    if (image.isEmpty()) return null;
    const size = image.getSize();
    const resized = size.width >= size.height
      ? image.resize({ width: 96, quality: 'good' })
      : image.resize({ height: 96, quality: 'good' });
    return PNG.sync.read(resized.toPNG(), { skipRescale: true });
  } catch {
    return null;
  }
}

function arrayBufferFor(buffer) {
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

async function decodePixels(filePath, knownWidth, knownHeight) {
  if (knownWidth && knownHeight && knownWidth * knownHeight > MAX_PIXEL_COUNT) return null;
  const stat = await fs.promises.stat(filePath);
  if (!stat.isFile() || stat.size > MAX_FILE_BYTES) return null;

  const ext = path.extname(filePath).toLowerCase();
  if (!SUPPORTED_EXTENSIONS.has(ext)) return null;
  if (ext === '.jpg' || ext === '.jpeg' || ext === '.png') {
    const native = decodeWithElectron(filePath);
    if (native) return native;
  }
  const buffer = await fs.promises.readFile(filePath);

  if (ext === '.jpg' || ext === '.jpeg') {
    return jpeg.decode(buffer, {
      useTArray: true,
      formatAsRGBA: true,
      maxResolutionInMP: 60,
      maxMemoryUsageInMB: 512,
    });
  }
  if (ext === '.png') return PNG.sync.read(buffer, { skipRescale: true });
  if (ext === '.heic' || ext === '.heif') return decodeHeic({ buffer });

  const source = arrayBufferFor(buffer);
  const pages = UTIF.decode(source);
  if (!pages.length) return null;
  UTIF.decodeImage(source, pages[0]);
  return {
    width: pages[0].width,
    height: pages[0].height,
    data: UTIF.toRGBA8(pages[0]),
  };
}

function transformedPoint(transform, x, y) {
  switch (transform) {
    case 1: return [1 - x, y];
    case 2: return [x, 1 - y];
    case 3: return [1 - x, 1 - y];
    case 4: return [y, x];
    case 5: return [1 - y, x];
    case 6: return [y, 1 - x];
    case 7: return [1 - y, 1 - x];
    default: return [x, y];
  }
}

function luminanceAt(image, normalizedX, normalizedY) {
  const x = Math.max(0, Math.min(image.width - 1, Math.round(normalizedX * (image.width - 1))));
  const y = Math.max(0, Math.min(image.height - 1, Math.round(normalizedY * (image.height - 1))));
  const offset = (y * image.width + x) * 4;
  const alpha = (image.data[offset + 3] ?? 255) / 255;
  const red = (image.data[offset] * alpha) + (255 * (1 - alpha));
  const green = (image.data[offset + 1] * alpha) + (255 * (1 - alpha));
  const blue = (image.data[offset + 2] * alpha) + (255 * (1 - alpha));
  return (red * 299 + green * 587 + blue * 114) / 1000;
}

function hashTransform(image, transform) {
  let hash = 0n;
  for (let row = 0; row < 8; row++) {
    const values = [];
    for (let column = 0; column < 9; column++) {
      const [x, y] = transformedPoint(transform, (column + 0.5) / 9, (row + 0.5) / 8);
      values.push(luminanceAt(image, x, y));
    }
    for (let column = 0; column < 8; column++) {
      hash = (hash << 1n) | (values[column] > values[column + 1] ? 1n : 0n);
    }
  }
  return hash.toString(16).padStart(16, '0');
}

async function computeVisualHashes(filePath, knownWidth = null, knownHeight = null) {
  try {
    const image = await decodePixels(filePath, knownWidth, knownHeight);
    if (!image || image.width < 9 || image.height < 8 || !image.data) return null;
    return Array.from({ length: 8 }, (_, transform) => hashTransform(image, transform));
  } catch {
    return null;
  }
}

function hammingDistance(left, right) {
  let value = BigInt(`0x${left}`) ^ BigInt(`0x${right}`);
  let count = 0;
  while (value) {
    value &= value - 1n;
    count++;
  }
  return count;
}

function minimumVisualDistance(leftHashes, rightHashes) {
  if (!leftHashes?.length || !rightHashes?.length) return null;
  let best = 64;
  for (const left of leftHashes) {
    for (const right of rightHashes) {
      best = Math.min(best, hammingDistance(left, right));
      if (best === 0) return 0;
    }
  }
  return best;
}

class VisualHashWorker {
  constructor() {
    this.worker = null;
    this.nextID = 1;
    this.pending = new Map();
  }

  start() {
    if (this.worker) return;
    let workerPath = path.join(__dirname, 'visual-hash-worker.js');
    // Node workers do not consistently load their entry point from an ASAR
    // archive on Windows. electron-builder ships this worker unpacked.
    if (workerPath.includes(`${path.sep}app.asar${path.sep}`)) {
      const unpackedPath = workerPath.replace(
        `${path.sep}app.asar${path.sep}`,
        `${path.sep}app.asar.unpacked${path.sep}`
      );
      if (fs.existsSync(unpackedPath)) workerPath = unpackedPath;
    }
    this.worker = new Worker(workerPath);
    this.worker.on('message', ({ id, hashes }) => {
      const request = this.pending.get(id);
      if (!request) return;
      this.pending.delete(id);
      request.resolve(hashes);
    });
    this.worker.on('error', error => {
      for (const request of this.pending.values()) request.reject(error);
      this.pending.clear();
    });
  }

  compute(filePath, knownWidth = null, knownHeight = null, signal = null) {
    const ext = path.extname(filePath).toLowerCase();
    // Electron's native decoder resizes JPEG/PNG before reading pixel data and
    // is fast enough on the main process. HEIC/TIFF decoding is moved off the
    // UI thread so the scanning animation and Cancel button remain responsive.
    if (ext === '.jpg' || ext === '.jpeg' || ext === '.png') {
      return computeVisualHashes(filePath, knownWidth, knownHeight);
    }
    this.start();
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.pending.delete(id);
        void this.close();
        const error = new Error('Visual comparison cancelled');
        error.name = 'AbortError';
        reject(error);
      };
      const cleanup = () => signal?.removeEventListener('abort', onAbort);
      this.pending.set(id, {
        resolve: value => { cleanup(); resolve(value); },
        reject: error => { cleanup(); reject(error); },
      });
      if (signal?.aborted) return onAbort();
      signal?.addEventListener('abort', onAbort, { once: true });
      this.worker.postMessage({ id, filePath, knownWidth, knownHeight });
    });
  }

  async close() {
    if (!this.worker) return;
    const worker = this.worker;
    this.worker = null;
    await worker.terminate();
    for (const request of this.pending.values()) request.resolve(null);
    this.pending.clear();
  }
}

module.exports = {
  computeVisualHashes,
  hammingDistance,
  minimumVisualDistance,
  VisualHashWorker,
  SUPPORTED_EXTENSIONS,
};
