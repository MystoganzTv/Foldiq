import React, { useEffect, useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  ScrollView, Alert, Platform,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as MediaLibrary from 'expo-media-library';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RootStackParamList } from '../navigation/AppNavigator';

type Props = {
  navigation: NativeStackNavigationProp<RootStackParamList, 'Home'>;
};

interface LibraryStats {
  photos: number;
  videos: number;
  totalAssets: number;
  oldestYear: number | null;
}

export default function HomeScreen({ navigation }: Props) {
  const [permission, requestPermission] = MediaLibrary.usePermissions();
  const [stats, setStats] = useState<LibraryStats | null>(null);

  useEffect(() => {
    if (permission?.granted) loadStats();
  }, [permission]);

  async function loadStats() {
    const photos = await MediaLibrary.getAssetsAsync({ mediaType: 'photo', first: 1 });
    const videos = await MediaLibrary.getAssetsAsync({ mediaType: 'video', first: 1 });
    const oldest = await MediaLibrary.getAssetsAsync({
      mediaType: ['photo', 'video'],
      first: 1,
      sortBy: [MediaLibrary.SortBy.creationTime],
    });
    const oldestYear = oldest.assets[0]
      ? new Date(oldest.assets[0].creationTime).getFullYear()
      : null;

    setStats({
      photos: photos.totalCount,
      videos: videos.totalCount,
      totalAssets: photos.totalCount + videos.totalCount,
      oldestYear,
    });
  }

  async function handlePermission() {
    if (!permission?.granted) {
      const result = await requestPermission();
      if (!result.granted) {
        Alert.alert(
          'Permission required',
          'Foldiq needs access to your photo library to back up your media.',
          [{ text: 'OK' }]
        );
      }
    }
  }

  const granted = permission?.granted ?? false;

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>

        {/* Header */}
        <View style={styles.header}>
          <View style={styles.logoRow}>
            <Ionicons name="folder-open" size={36} color="#3B82F6" />
            <Text style={styles.logoText}>Foldiq</Text>
          </View>
          <Text style={styles.headline}>Back up your photos</Text>
          <Text style={styles.subtitle}>
            Export your camera roll to an organized folder — on your phone, in iCloud, Google Drive, or Dropbox.
          </Text>
        </View>

        {/* Permission banner */}
        {!granted && (
          <TouchableOpacity style={styles.permissionBanner} onPress={handlePermission}>
            <Ionicons name="images-outline" size={22} color="#3B82F6" />
            <View style={styles.permissionText}>
              <Text style={styles.permissionTitle}>Allow photo access</Text>
              <Text style={styles.permissionDetail}>Tap to grant access to your library</Text>
            </View>
            <Ionicons name="chevron-forward" size={18} color="#94A3B8" />
          </TouchableOpacity>
        )}

        {/* Stats */}
        {granted && stats && (
          <View style={styles.statsRow}>
            <StatCard icon="image-outline" value={stats.photos.toLocaleString()} label="Photos" color="#3B82F6" />
            <StatCard icon="videocam-outline" value={stats.videos.toLocaleString()} label="Videos" color="#8B5CF6" />
            {stats.oldestYear && (
              <StatCard icon="calendar-outline" value={`Since ${stats.oldestYear}`} label="Oldest" color="#10B981" />
            )}
          </View>
        )}

        {/* How it works */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>How it works</Text>
          {[
            { icon: 'checkmark-circle-outline', text: 'Select photos — all or just what you want' },
            { icon: 'folder-outline', text: 'Foldiq organizes them by date into clean folders' },
            { icon: 'cloud-upload-outline', text: 'Export to your phone, iCloud, Google Drive, or Dropbox' },
          ].map((step, i) => (
            <View key={i} style={styles.stepRow}>
              <Ionicons name={step.icon as any} size={20} color="#3B82F6" />
              <Text style={styles.stepText}>{step.text}</Text>
            </View>
          ))}
        </View>

        {/* CTA Buttons */}
        <View style={styles.ctaSection}>
          <TouchableOpacity
            style={[styles.ctaPrimary, !granted && styles.ctaDisabled]}
            onPress={() => granted && navigation.navigate('Select')}
            disabled={!granted}
          >
            <Ionicons name="images" size={22} color="#fff" />
            <Text style={styles.ctaPrimaryText}>Browse & Select Photos</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.ctaSecondary, !granted && styles.ctaDisabled]}
            onPress={async () => {
              if (!granted) return;
              // Export all — go straight to Export with all assets pre-selected
              navigation.navigate('Export', { selectedAssets: [] }); // [] = export all
            }}
            disabled={!granted}
          >
            <Ionicons name="download-outline" size={20} color="#3B82F6" />
            <Text style={styles.ctaSecondaryText}>Export Entire Library</Text>
          </TouchableOpacity>
        </View>

      </ScrollView>
    </SafeAreaView>
  );
}

function StatCard({ icon, value, label, color }: { icon: string; value: string; label: string; color: string }) {
  return (
    <View style={styles.statCard}>
      <Ionicons name={icon as any} size={22} color={color} />
      <Text style={[styles.statValue, { color }]}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#F8FAFC' },
  scroll: { padding: 24, paddingBottom: 48 },
  header: { marginBottom: 28 },
  logoRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 16 },
  logoText: { fontSize: 24, fontWeight: '700', color: '#1E293B' },
  headline: { fontSize: 32, fontWeight: '800', color: '#1E293B', marginBottom: 8 },
  subtitle: { fontSize: 16, color: '#64748B', lineHeight: 24 },

  permissionBanner: {
    flexDirection: 'row', alignItems: 'center', backgroundColor: '#EFF6FF',
    borderRadius: 14, padding: 16, gap: 12, marginBottom: 20,
    borderWidth: 1, borderColor: '#BFDBFE',
  },
  permissionText: { flex: 1 },
  permissionTitle: { fontSize: 15, fontWeight: '600', color: '#1E40AF' },
  permissionDetail: { fontSize: 13, color: '#3B82F6', marginTop: 2 },

  statsRow: { flexDirection: 'row', gap: 12, marginBottom: 28 },
  statCard: {
    flex: 1, backgroundColor: '#fff', borderRadius: 14, padding: 16,
    alignItems: 'center', gap: 6,
    shadowColor: '#000', shadowOpacity: 0.04, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 2,
  },
  statValue: { fontSize: 18, fontWeight: '700' },
  statLabel: { fontSize: 12, color: '#94A3B8' },

  section: { backgroundColor: '#fff', borderRadius: 14, padding: 20, marginBottom: 28, gap: 14,
    shadowColor: '#000', shadowOpacity: 0.04, shadowRadius: 8, shadowOffset: { width: 0, height: 2 }, elevation: 2,
  },
  sectionTitle: { fontSize: 16, fontWeight: '700', color: '#1E293B', marginBottom: 4 },
  stepRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  stepText: { flex: 1, fontSize: 14, color: '#475569', lineHeight: 20 },

  ctaSection: { gap: 12 },
  ctaPrimary: {
    backgroundColor: '#3B82F6', borderRadius: 16, padding: 18,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
  },
  ctaPrimaryText: { color: '#fff', fontSize: 17, fontWeight: '700' },
  ctaSecondary: {
    backgroundColor: '#fff', borderRadius: 16, padding: 18,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    borderWidth: 1.5, borderColor: '#BFDBFE',
  },
  ctaSecondaryText: { color: '#3B82F6', fontSize: 17, fontWeight: '600' },
  ctaDisabled: { opacity: 0.4 },
});
