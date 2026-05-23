/**
 * Google Drive export service.
 *
 * Setup required:
 * 1. Create an OAuth 2.0 Client ID at console.cloud.google.com
 *    (type: iOS for iOS, Android for Android)
 * 2. Enable the Google Drive API
 * 3. Set your client ID in app.json → extra.googleClientId
 *
 * The access token is obtained via expo-auth-session in ExportScreen
 * and passed here for uploads.
 */

const DRIVE_UPLOAD_URL =
  'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart';
const DRIVE_FOLDER_URL = 'https://www.googleapis.com/drive/v3/files';

/** Creates a folder in Google Drive. Returns the folder ID. */
export async function createDriveFolder(
  name: string,
  parentId: string | null,
  accessToken: string
): Promise<string> {
  const metadata: Record<string, unknown> = {
    name,
    mimeType: 'application/vnd.google-apps.folder',
  };
  if (parentId) metadata.parents = [parentId];

  const res = await fetch(DRIVE_FOLDER_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(metadata),
  });

  if (!res.ok) throw new Error(`Drive folder creation failed: ${res.status}`);
  const json = await res.json();
  return json.id as string;
}

/** Finds a folder by name under a parent (or root). Returns ID or null. */
export async function findDriveFolder(
  name: string,
  parentId: string | null,
  accessToken: string
): Promise<string | null> {
  const parent = parentId ? `'${parentId}'` : "'root'";
  const q = encodeURIComponent(
    `name='${name}' and mimeType='application/vnd.google-apps.folder' and ${parent} in parents and trashed=false`
  );
  const res = await fetch(`${DRIVE_FOLDER_URL}?q=${q}&fields=files(id,name)`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) return null;
  const json = await res.json();
  return json.files?.[0]?.id ?? null;
}

/** Gets or creates a nested folder path like "Foldiq Backup/2026/2026-05 May". */
export async function ensureDrivePath(
  pathParts: string[],
  accessToken: string
): Promise<string> {
  let parentId: string | null = null;
  for (const part of pathParts) {
    const existing = await findDriveFolder(part, parentId, accessToken);
    if (existing) {
      parentId = existing;
    } else {
      parentId = await createDriveFolder(part, parentId, accessToken);
    }
  }
  return parentId!;
}

/** Uploads a file blob to a specific Drive folder. */
export async function uploadFileToDrive(
  filename: string,
  mimeType: string,
  blob: Blob,
  folderId: string,
  accessToken: string
): Promise<void> {
  const metadata = JSON.stringify({ name: filename, parents: [folderId] });

  const form = new FormData();
  form.append('metadata', new Blob([metadata], { type: 'application/json' }));
  form.append('file', blob, filename);

  const res = await fetch(DRIVE_UPLOAD_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}` },
    body: form,
  });

  if (!res.ok) throw new Error(`Drive upload failed: ${res.status} ${await res.text()}`);
}
