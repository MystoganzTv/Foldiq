/**
 * Core export engine — coordinates reading from the photo library
 * and writing to the chosen destination.
 */

import * as FileSystem from 'expo-file-system';
import * as MediaLibrary from 'expo-media-library';
import { MediaAsset, ExportConfig, ExportProgress } from '../utils/types';
import { folderPath, destinationFilename } from '../utils/organizer';
import { ensureDrivePath, uploadFileToDrive } from './googleDrive';
import { ensureDropboxPath, uploadFileToDropbox } from './dropbox';

type ProgressCallback = (progress: ExportProgress) => void;

/** Main export function. Calls onProgress as each file is processed. */
export async function runExport(
  assets: MediaAsset[],
  config: ExportConfig,
  onProgress: ProgressCallback,
  cancelRef: { cancelled: boolean }
): Promise<ExportProgress> {
  const progress: ExportProgress = {
    total: assets.length,
    done: 0,
    currentFile: '',
    errors: [],
    finished: false,
  };

  for (const asset of assets) {
    if (cancelRef.cancelled) break;

    progress.currentFile = asset.filename;
    onProgress({ ...progress });

    try {
      const relFolder = folderPath(asset, config.mode);
      const filename = destinationFilename(asset);
      const fullPath = `${config.folderName}/${relFolder}/${filename}`;

      switch (config.destination) {
        case 'local':
        case 'icloud':
          await exportToLocal(asset, config.destinationUri!, relFolder, filename);
          break;
        case 'googledrive':
          await exportToGoogleDrive(asset, config, relFolder, filename, fullPath);
          break;
        case 'dropbox':
          await exportToDropbox(asset, config, fullPath);
          break;
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      progress.errors.push(`${asset.filename}: ${msg}`);
    }

    progress.done += 1;
    onProgress({ ...progress });
  }

  progress.currentFile = '';
  progress.finished = true;
  onProgress({ ...progress });
  return progress;
}

// ── Local / iCloud Drive ───────────────────────────────────────────────────────

async function exportToLocal(
  asset: MediaAsset,
  baseUri: string,
  relFolder: string,
  filename: string
): Promise<void> {
  // Build destination dir path
  const destDir = `${baseUri}/${relFolder}/`;
  await FileSystem.makeDirectoryAsync(destDir, { intermediates: true });
  const destPath = `${destDir}${filename}`;

  // Get the local URI of the asset
  const info = await MediaLibrary.getAssetInfoAsync(asset);
  const sourceUri = info.localUri ?? info.uri;

  await FileSystem.copyAsync({ from: sourceUri, to: destPath });
}

// ── Google Drive ───────────────────────────────────────────────────────────────

async function exportToGoogleDrive(
  asset: MediaAsset,
  config: ExportConfig,
  relFolder: string,
  filename: string,
  _fullPath: string
): Promise<void> {
  const token = config.accessToken!;
  const pathParts = [config.folderName, ...relFolder.split('/')];
  const folderId = await ensureDrivePath(pathParts, token);

  // Read file as blob
  const info = await MediaLibrary.getAssetInfoAsync(asset);
  const sourceUri = info.localUri ?? info.uri;
  const base64 = await FileSystem.readAsStringAsync(sourceUri, {
    encoding: FileSystem.EncodingType.Base64,
  });
  const mimeType = asset.mediaType === 'video' ? 'video/mp4' : 'image/jpeg';
  const byteArray = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  const blob = new Blob([byteArray], { type: mimeType });

  await uploadFileToDrive(filename, mimeType, blob, folderId, token);
}

// ── Dropbox ────────────────────────────────────────────────────────────────────

async function exportToDropbox(
  asset: MediaAsset,
  config: ExportConfig,
  fullPath: string
): Promise<void> {
  const token = config.accessToken!;
  const pathParts = ['/', ...fullPath.split('/')];
  await ensureDropboxPath(pathParts.slice(0, -1), token);

  const info = await MediaLibrary.getAssetInfoAsync(asset);
  const sourceUri = info.localUri ?? info.uri;
  const base64 = await FileSystem.readAsStringAsync(sourceUri, {
    encoding: FileSystem.EncodingType.Base64,
  });
  const byteArray = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  const blob = new Blob([byteArray]);

  await uploadFileToDropbox(`/${fullPath}`, blob, token);
}
