/**
 * Dropbox export service.
 *
 * Setup required:
 * 1. Create an app at dropbox.com/developers
 * 2. Set redirect URI to: exp://YOUR_EXPO_HOST/--/dropbox-auth
 * 3. Add your app key to app.json → extra.dropboxAppKey
 *
 * The access token is obtained via expo-auth-session in ExportScreen.
 */

const DROPBOX_UPLOAD_URL = 'https://content.dropboxapi.com/2/files/upload';
const DROPBOX_FOLDER_URL = 'https://api.dropboxapi.com/2/files/create_folder_v2';

/** Creates a Dropbox folder at the given path. Ignores "already exists" errors. */
export async function createDropboxFolder(
  path: string,
  accessToken: string
): Promise<void> {
  const res = await fetch(DROPBOX_FOLDER_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ path, autorename: false }),
  });

  if (!res.ok) {
    const err = await res.json();
    // "path/conflict/folder" means it already exists — that's fine
    const tag = err?.error?.['.tag'] ?? '';
    if (!tag.includes('conflict')) {
      throw new Error(`Dropbox folder creation failed: ${res.status}`);
    }
  }
}

/** Ensures all folders in a path exist on Dropbox. */
export async function ensureDropboxPath(
  pathParts: string[],
  accessToken: string
): Promise<string> {
  let current = '';
  for (const part of pathParts) {
    current += `/${part}`;
    await createDropboxFolder(current, accessToken);
  }
  return current;
}

/** Uploads a file to Dropbox at the given path. */
export async function uploadFileToDropbox(
  dropboxPath: string,
  blob: Blob,
  accessToken: string
): Promise<void> {
  const res = await fetch(DROPBOX_UPLOAD_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/octet-stream',
      'Dropbox-API-Arg': JSON.stringify({
        path: dropboxPath,
        mode: 'add',
        autorename: true,
        mute: false,
      }),
    },
    body: blob,
  });

  if (!res.ok) throw new Error(`Dropbox upload failed: ${res.status} ${await res.text()}`);
}
