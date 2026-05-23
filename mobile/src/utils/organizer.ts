import { MediaAsset, OrganizationMode } from './types';

const MONTH_NAMES = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December',
];

function pad(n: number): string {
  return n.toString().padStart(2, '0');
}

/**
 * Returns the relative folder path for a given asset under the chosen mode.
 * e.g. "2026/2026-05 May/2026-05-18"
 */
export function folderPath(asset: MediaAsset, mode: OrganizationMode): string {
  const date = new Date(asset.creationTime);
  const year = date.getFullYear();
  const month = date.getMonth(); // 0-indexed
  const day = date.getDate();

  const yearStr = year.toString();
  const monthFolder = `${yearStr}-${pad(month + 1)} ${MONTH_NAMES[month]}`;
  const dayFolder = `${yearStr}-${pad(month + 1)}-${pad(day)}`;

  switch (mode) {
    case 'byYear':
      return yearStr;
    case 'byYearMonth':
      return `${yearStr}/${monthFolder}`;
    case 'byExactDate':
      return `${yearStr}/${monthFolder}/${dayFolder}`;
    case 'smartHybrid':
    default:
      return `${yearStr}/${monthFolder}/${dayFolder}`;
  }
}

/** Returns the destination filename for an asset. */
export function destinationFilename(asset: MediaAsset): string {
  return asset.filename;
}

/** Groups assets by their folder path under a given mode. */
export function groupByFolder(
  assets: MediaAsset[],
  mode: OrganizationMode
): Map<string, MediaAsset[]> {
  const map = new Map<string, MediaAsset[]>();
  for (const asset of assets) {
    const folder = folderPath(asset, mode);
    const existing = map.get(folder) ?? [];
    existing.push(asset);
    map.set(folder, existing);
  }
  return map;
}

/** Returns a human-readable summary of what will be exported. */
export function exportSummary(
  assets: MediaAsset[],
  mode: OrganizationMode
): { folders: number; photos: number; videos: number; totalBytes: number } {
  const grouped = groupByFolder(assets, mode);
  const photos = assets.filter(a => a.mediaType === 'photo').length;
  const videos = assets.filter(a => a.mediaType === 'video').length;
  const totalBytes = assets.reduce((sum, a) => sum + (a.fileSize ?? 0), 0);
  return { folders: grouped.size, photos, videos, totalBytes };
}
