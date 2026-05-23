import * as MediaLibrary from 'expo-media-library';

export type MediaAsset = MediaLibrary.Asset;

export type OrganizationMode =
  | 'smartHybrid'
  | 'byYear'
  | 'byYearMonth'
  | 'byExactDate';

export type ExportDestination =
  | 'local'      // Files app / HDD — system document picker
  | 'icloud'     // iCloud Drive via Files picker
  | 'googledrive'
  | 'dropbox';

export interface ExportConfig {
  mode: OrganizationMode;
  destination: ExportDestination;
  folderName: string;
  includeVideos: boolean;
  destinationUri?: string;   // picked folder URI (local / iCloud)
  accessToken?: string;      // OAuth token (Google Drive / Dropbox)
}

export interface ExportProgress {
  total: number;
  done: number;
  currentFile: string;
  errors: string[];
  finished: boolean;
}

export const ORGANIZATION_MODES: { key: OrganizationMode; label: string; detail: string; example: string }[] = [
  {
    key: 'smartHybrid',
    label: 'Smart Hybrid',
    detail: 'Year → Month → Date with location when available. Best for most libraries.',
    example: '2026/\n  2026-05 May/\n    2026-05-18 Herndon VA/',
  },
  {
    key: 'byYear',
    label: 'By Year',
    detail: 'One folder per year. Simple and fast.',
    example: '2026/\n2025/\n2024/',
  },
  {
    key: 'byYearMonth',
    label: 'By Year & Month',
    detail: 'One folder per month, grouped by year.',
    example: '2026/\n  2026-05 May/\n  2026-04 April/',
  },
  {
    key: 'byExactDate',
    label: 'By Exact Date',
    detail: 'One folder per day. Most granular.',
    example: '2026/\n  2026-05 May/\n    2026-05-18/',
  },
];
