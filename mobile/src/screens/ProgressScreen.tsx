import React, { useEffect, useRef, useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  ScrollView, Alert,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RouteProp } from '@react-navigation/native';
import { RootStackParamList } from '../navigation/AppNavigator';
import { ExportProgress } from '../utils/types';
import { runExport } from '../services/exporter';

type Props = {
  navigation: NativeStackNavigationProp<RootStackParamList, 'Progress'>;
  route: RouteProp<RootStackParamList, 'Progress'>;
};

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export default function ProgressScreen({ navigation, route }: Props) {
  const { selectedAssets, config } = route.params;
  const cancelRef = useRef({ cancelled: false });

  const [progress, setProgress] = useState<ExportProgress>({
    total: selectedAssets.length,
    done: 0,
    currentFile: '',
    errors: [],
    finished: false,
  });

  useEffect(() => {
    start();
    return () => { cancelRef.current.cancelled = true; };
  }, []);

  async function start() {
    try {
      await runExport(selectedAssets, config, setProgress, cancelRef.current);
    } catch (err) {
      Alert.alert('Export error', String(err));
    }
  }

  function cancel() {
    cancelRef.current.cancelled = true;
    navigation.goBack();
  }

  function done() {
    navigation.popToTop();
  }

  const pct = progress.total > 0 ? progress.done / progress.total : 0;
  const finished = progress.finished || (cancelRef.current.cancelled && progress.done > 0);

  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.content}>

        {/* Icon */}
        <View style={[styles.iconCircle, finished && styles.iconCircleDone]}>
          {finished ? (
            <Ionicons name="checkmark" size={48} color="#fff" />
          ) : (
            <Ionicons name="cloud-upload-outline" size={48} color="#3B82F6" />
          )}
        </View>

        {/* Title */}
        <Text style={styles.title}>
          {finished
            ? progress.errors.length > 0 ? 'Finished with errors' : 'Export complete!'
            : 'Exporting…'}
        </Text>

        {/* Progress bar */}
        <View style={styles.barTrack}>
          <View style={[styles.barFill, { width: `${Math.round(pct * 100)}%` }]} />
        </View>

        {/* Count */}
        <Text style={styles.countText}>
          {progress.done.toLocaleString()} / {progress.total.toLocaleString()}
          {'  '}
          <Text style={styles.pctText}>{Math.round(pct * 100)}%</Text>
        </Text>

        {/* Current file */}
        {!finished && progress.currentFile !== '' && (
          <Text style={styles.currentFile} numberOfLines={1}>
            {progress.currentFile}
          </Text>
        )}

        {/* Destination reminder */}
        <View style={styles.destBadge}>
          <Ionicons
            name={
              config.destination === 'googledrive' ? 'logo-google' :
              config.destination === 'dropbox' ? 'cube-outline' :
              config.destination === 'icloud' ? 'cloud-outline' :
              'phone-portrait-outline'
            }
            size={16} color="#64748B"
          />
          <Text style={styles.destText}>
            {config.destination === 'local' ? 'Phone / HDD' :
             config.destination === 'icloud' ? 'iCloud Drive' :
             config.destination === 'googledrive' ? 'Google Drive' : 'Dropbox'}
            {'  ›  '}{config.folderName}
          </Text>
        </View>

        {/* Errors */}
        {progress.errors.length > 0 && (
          <View style={styles.errorsBox}>
            <Text style={styles.errorsTitle}>{progress.errors.length} file{progress.errors.length > 1 ? 's' : ''} failed</Text>
            <ScrollView style={{ maxHeight: 120 }}>
              {progress.errors.map((e, i) => (
                <Text key={i} style={styles.errorLine} numberOfLines={2}>{e}</Text>
              ))}
            </ScrollView>
          </View>
        )}

      </View>

      {/* Footer */}
      <View style={styles.footer}>
        {!finished ? (
          <TouchableOpacity style={styles.cancelBtn} onPress={cancel}>
            <Text style={styles.cancelText}>Cancel</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity style={styles.doneBtn} onPress={done}>
            <Ionicons name="home-outline" size={20} color="#fff" />
            <Text style={styles.doneText}>Back to Home</Text>
          </TouchableOpacity>
        )}
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#F8FAFC' },
  content: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 32, gap: 20 },

  iconCircle: {
    width: 100, height: 100, borderRadius: 50,
    backgroundColor: '#EFF6FF',
    alignItems: 'center', justifyContent: 'center',
  },
  iconCircleDone: { backgroundColor: '#10B981' },

  title: { fontSize: 26, fontWeight: '800', color: '#1E293B', textAlign: 'center' },

  barTrack: {
    width: '100%', height: 10, backgroundColor: '#E2E8F0',
    borderRadius: 5, overflow: 'hidden',
  },
  barFill: {
    height: 10, backgroundColor: '#3B82F6', borderRadius: 5,
    minWidth: 10,
  },

  countText: { fontSize: 18, fontWeight: '600', color: '#1E293B' },
  pctText: { color: '#3B82F6' },

  currentFile: { fontSize: 13, color: '#64748B', textAlign: 'center', maxWidth: 300 },

  destBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: '#fff', borderRadius: 20, paddingHorizontal: 16, paddingVertical: 8,
    borderWidth: 1, borderColor: '#E2E8F0',
  },
  destText: { fontSize: 13, color: '#64748B' },

  errorsBox: {
    width: '100%', backgroundColor: '#FFF1F2', borderRadius: 12,
    padding: 14, borderWidth: 1, borderColor: '#FECDD3',
  },
  errorsTitle: { fontSize: 13, fontWeight: '700', color: '#E11D48', marginBottom: 6 },
  errorLine: { fontSize: 12, color: '#9F1239', marginBottom: 3 },

  footer: { padding: 16, paddingBottom: 8 },
  cancelBtn: {
    borderWidth: 1.5, borderColor: '#E2E8F0', borderRadius: 16,
    padding: 18, alignItems: 'center',
  },
  cancelText: { fontSize: 16, fontWeight: '600', color: '#64748B' },
  doneBtn: {
    backgroundColor: '#10B981', borderRadius: 16, padding: 18,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
  },
  doneText: { color: '#fff', fontSize: 17, fontWeight: '700' },
});
