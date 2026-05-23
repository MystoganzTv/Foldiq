import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  ScrollView, TextInput, Alert, ActivityIndicator,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import * as FileSystem from 'expo-file-system';
import * as MediaLibrary from 'expo-media-library';
import * as AuthSession from 'expo-auth-session';
import * as WebBrowser from 'expo-web-browser';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RouteProp } from '@react-navigation/native';
import { RootStackParamList } from '../navigation/AppNavigator';
import { ExportConfig, ExportDestination, OrganizationMode, ORGANIZATION_MODES } from '../utils/types';
import { exportSummary } from '../utils/organizer';

WebBrowser.maybeCompleteAuthSession();

type Props = {
  navigation: NativeStackNavigationProp<RootStackParamList, 'Export'>;
  route: RouteProp<RootStackParamList, 'Export'>;
};

const DESTINATIONS: { key: ExportDestination; icon: string; label: string; detail: string; color: string }[] = [
  { key: 'local',       icon: 'phone-portrait-outline', label: 'Phone / HDD',   detail: 'Save to Files app — includes USB drives and local storage', color: '#6366F1' },
  { key: 'icloud',      icon: 'cloud-outline',          label: 'iCloud Drive',  detail: 'Save directly to a folder in your iCloud Drive',            color: '#0EA5E9' },
  { key: 'googledrive', icon: 'logo-google',            label: 'Google Drive',  detail: 'Sign in with Google and export to your Drive',              color: '#10B981' },
  { key: 'dropbox',     icon: 'cube-outline',           label: 'Dropbox',       detail: 'Sign in to Dropbox and export to a folder',                 color: '#0061FF' },
];

// OAuth config — replace with real values in app.json extra
const GOOGLE_CLIENT_ID = 'YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com';
const DROPBOX_APP_KEY  = 'YOUR_DROPBOX_APP_KEY';

export default function ExportScreen({ navigation, route }: Props) {
  const { selectedAssets } = route.params;

  const [mode, setMode]               = useState<OrganizationMode>('smartHybrid');
  const [destination, setDestination] = useState<ExportDestination>('local');
  const [folderName, setFolderName]   = useState('Foldiq Backup');
  const [destUri, setDestUri]         = useState<string | undefined>(undefined);
  const [accessToken, setAccessToken] = useState<string | undefined>(undefined);
  const [connecting, setConnecting]   = useState(false);
  const [showModes, setShowModes]     = useState(false);

  // Compute summary (selectedAssets=[] means export all — load count from library)
  const assetCount = selectedAssets.length === 0 ? null : selectedAssets.length;

  // ── OAuth helpers ──────────────────────────────────────────────────────────

  async function connectGoogle() {
    setConnecting(true);
    try {
      const redirectUri = AuthSession.makeRedirectUri({ scheme: 'foldiq' });
      const authUrl =
        `https://accounts.google.com/o/oauth2/v2/auth?` +
        `client_id=${GOOGLE_CLIENT_ID}&redirect_uri=${encodeURIComponent(redirectUri)}` +
        `&response_type=token&scope=${encodeURIComponent('https://www.googleapis.com/auth/drive.file')}`;

      const result = await WebBrowser.openAuthSessionAsync(authUrl, redirectUri);
      if (result.type === 'success') {
        const params = new URLSearchParams(result.url.split('#')[1]);
        const token = params.get('access_token');
        if (token) { setAccessToken(token); Alert.alert('Google Drive connected ✓'); }
      }
    } finally { setConnecting(false); }
  }

  async function connectDropbox() {
    setConnecting(true);
    try {
      const redirectUri = AuthSession.makeRedirectUri({ scheme: 'foldiq' });
      const authUrl =
        `https://www.dropbox.com/oauth2/authorize?` +
        `client_id=${DROPBOX_APP_KEY}&redirect_uri=${encodeURIComponent(redirectUri)}` +
        `&response_type=token`;

      const result = await WebBrowser.openAuthSessionAsync(authUrl, redirectUri);
      if (result.type === 'success') {
        const params = new URLSearchParams(result.url.split('#')[1]);
        const token = params.get('access_token');
        if (token) { setAccessToken(token); Alert.alert('Dropbox connected ✓'); }
      }
    } finally { setConnecting(false); }
  }

  async function pickDestinationFolder() {
    const result = await DocumentPicker.getDocumentAsync({
      type: 'public.folder',
      copyToCacheDirectory: false,
    });
    if (!result.canceled && result.assets[0]) {
      setDestUri(result.assets[0].uri);
    }
  }

  // ── Destination selection handler ──────────────────────────────────────────

  async function handleSelectDestination(key: ExportDestination) {
    setDestination(key);
    setAccessToken(undefined);
    setDestUri(undefined);

    if (key === 'local' || key === 'icloud') {
      await pickDestinationFolder();
    } else if (key === 'googledrive') {
      await connectGoogle();
    } else if (key === 'dropbox') {
      await connectDropbox();
    }
  }

  // ── Validation & start ─────────────────────────────────────────────────────

  function canStart(): boolean {
    if ((destination === 'local' || destination === 'icloud') && !destUri) return false;
    if ((destination === 'googledrive' || destination === 'dropbox') && !accessToken) return false;
    return true;
  }

  async function startExport() {
    // If selectedAssets=[] we load all from library before proceeding
    let assets = selectedAssets;
    if (assets.length === 0) {
      const all = await MediaLibrary.getAssetsAsync({
        mediaType: ['photo', 'video'],
        first: 99999,
        sortBy: [MediaLibrary.SortBy.creationTime],
      });
      assets = all.assets;
    }

    const config: ExportConfig = {
      mode,
      destination,
      folderName,
      includeVideos: true,
      destinationUri: destUri,
      accessToken,
    };

    navigation.navigate('Progress', { selectedAssets: assets, config });
  }

  const selectedMode = ORGANIZATION_MODES.find(m => m.key === mode)!;

  return (
    <SafeAreaView style={styles.container}>
      {/* Navbar */}
      <View style={styles.navbar}>
        <TouchableOpacity onPress={() => navigation.goBack()} style={styles.navBtn}>
          <Ionicons name="chevron-back" size={24} color="#3B82F6" />
        </TouchableOpacity>
        <Text style={styles.navTitle}>Export Settings</Text>
        <View style={{ width: 40 }} />
      </View>

      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>

        {/* Count summary */}
        <View style={styles.summaryBanner}>
          <Ionicons name="images-outline" size={20} color="#3B82F6" />
          <Text style={styles.summaryText}>
            {assetCount !== null
              ? `${assetCount.toLocaleString()} items selected`
              : 'Exporting entire library'}
          </Text>
        </View>

        {/* Organization mode */}
        <View style={styles.card}>
          <Text style={styles.cardTitle}>Organization</Text>
          <TouchableOpacity style={styles.modeRow} onPress={() => setShowModes(!showModes)}>
            <View style={{ flex: 1 }}>
              <Text style={styles.modeLabel}>{selectedMode.label}</Text>
              <Text style={styles.modeDetail} numberOfLines={1}>{selectedMode.detail}</Text>
            </View>
            <Ionicons name={showModes ? 'chevron-up' : 'chevron-down'} size={18} color="#94A3B8" />
          </TouchableOpacity>

          {showModes && ORGANIZATION_MODES.map(m => (
            <TouchableOpacity
              key={m.key}
              style={[styles.modeOption, m.key === mode && styles.modeOptionSelected]}
              onPress={() => { setMode(m.key); setShowModes(false); }}
            >
              <View style={{ flex: 1 }}>
                <Text style={[styles.modeOptionLabel, m.key === mode && { color: '#3B82F6' }]}>{m.label}</Text>
                <Text style={styles.modeOptionDetail}>{m.detail}</Text>
                <Text style={styles.modeExample}>{m.example}</Text>
              </View>
              {m.key === mode && <Ionicons name="checkmark-circle" size={20} color="#3B82F6" />}
            </TouchableOpacity>
          ))}
        </View>

        {/* Destination */}
        <View style={styles.card}>
          <Text style={styles.cardTitle}>Destination</Text>
          {DESTINATIONS.map(d => {
            const active = destination === d.key;
            const connected = active && (destUri !== undefined || accessToken !== undefined);
            return (
              <TouchableOpacity
                key={d.key}
                style={[styles.destRow, active && styles.destRowActive]}
                onPress={() => handleSelectDestination(d.key)}
              >
                <View style={[styles.destIcon, { backgroundColor: d.color + '18' }]}>
                  <Ionicons name={d.icon as any} size={22} color={d.color} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={[styles.destLabel, active && { color: '#3B82F6' }]}>{d.label}</Text>
                  <Text style={styles.destDetail}>
                    {connected ? '✓ Connected' : d.detail}
                  </Text>
                </View>
                {active && <Ionicons name="checkmark-circle" size={20} color="#3B82F6" />}
              </TouchableOpacity>
            );
          })}
          {connecting && (
            <View style={styles.connectingRow}>
              <ActivityIndicator size="small" color="#3B82F6" />
              <Text style={styles.connectingText}>Connecting…</Text>
            </View>
          )}
        </View>

        {/* Folder name */}
        <View style={styles.card}>
          <Text style={styles.cardTitle}>Backup folder name</Text>
          <TextInput
            style={styles.input}
            value={folderName}
            onChangeText={setFolderName}
            placeholder="Foldiq Backup"
            placeholderTextColor="#94A3B8"
          />
        </View>

      </ScrollView>

      {/* Footer */}
      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.startBtn, !canStart() && styles.startBtnDisabled]}
          onPress={startExport}
          disabled={!canStart()}
        >
          <Ionicons name="download" size={20} color="#fff" />
          <Text style={styles.startText}>Start Export</Text>
        </TouchableOpacity>
        {!canStart() && (
          <Text style={styles.footerHint}>
            {(destination === 'local' || destination === 'icloud')
              ? 'Tap the destination to choose a folder'
              : 'Connect your account to continue'}
          </Text>
        )}
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#F8FAFC' },
  navbar: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: 8, paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#E2E8F0',
    backgroundColor: '#fff',
  },
  navBtn: { padding: 8 },
  navTitle: { fontSize: 17, fontWeight: '700', color: '#1E293B' },
  scroll: { padding: 16, gap: 16, paddingBottom: 32 },

  summaryBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: '#EFF6FF', borderRadius: 12, padding: 14,
    borderWidth: 1, borderColor: '#BFDBFE',
  },
  summaryText: { fontSize: 15, fontWeight: '600', color: '#1E40AF' },

  card: {
    backgroundColor: '#fff', borderRadius: 16, padding: 16, gap: 12,
    shadowColor: '#000', shadowOpacity: 0.04, shadowRadius: 8, shadowOffset: { width: 0, height: 2 }, elevation: 2,
  },
  cardTitle: { fontSize: 13, fontWeight: '700', color: '#94A3B8', textTransform: 'uppercase', letterSpacing: 0.5 },

  modeRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  modeLabel: { fontSize: 15, fontWeight: '600', color: '#1E293B' },
  modeDetail: { fontSize: 13, color: '#64748B', marginTop: 2 },
  modeOption: { padding: 12, borderRadius: 10, borderWidth: 1, borderColor: '#E2E8F0', gap: 4 },
  modeOptionSelected: { borderColor: '#3B82F6', backgroundColor: '#EFF6FF' },
  modeOptionLabel: { fontSize: 14, fontWeight: '600', color: '#1E293B' },
  modeOptionDetail: { fontSize: 12, color: '#64748B' },
  modeExample: { fontFamily: 'monospace', fontSize: 11, color: '#94A3B8', marginTop: 4 },

  destRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12, padding: 12,
    borderRadius: 12, borderWidth: 1, borderColor: '#E2E8F0',
  },
  destRowActive: { borderColor: '#3B82F6', backgroundColor: '#EFF6FF' },
  destIcon: { width: 44, height: 44, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
  destLabel: { fontSize: 15, fontWeight: '600', color: '#1E293B' },
  destDetail: { fontSize: 12, color: '#64748B', marginTop: 2 },
  connectingRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingTop: 4 },
  connectingText: { color: '#64748B', fontSize: 14 },

  input: {
    borderWidth: 1, borderColor: '#E2E8F0', borderRadius: 10,
    padding: 12, fontSize: 15, color: '#1E293B', backgroundColor: '#F8FAFC',
  },

  footer: { padding: 16, gap: 8, backgroundColor: '#fff', borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: '#E2E8F0' },
  startBtn: {
    backgroundColor: '#3B82F6', borderRadius: 16, padding: 18,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
  },
  startBtnDisabled: { backgroundColor: '#CBD5E1' },
  startText: { color: '#fff', fontSize: 17, fontWeight: '700' },
  footerHint: { textAlign: 'center', fontSize: 13, color: '#94A3B8' },
});
