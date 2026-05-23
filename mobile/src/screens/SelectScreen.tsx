import React, { useEffect, useState, useCallback } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  FlatList, Dimensions, ActivityIndicator,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Image } from 'expo-image';
import { Ionicons } from '@expo/vector-icons';
import * as MediaLibrary from 'expo-media-library';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RouteProp } from '@react-navigation/native';
import { RootStackParamList } from '../navigation/AppNavigator';
import { MediaAsset } from '../utils/types';

type Props = {
  navigation: NativeStackNavigationProp<RootStackParamList, 'Select'>;
  route: RouteProp<RootStackParamList, 'Select'>;
};

const COLUMNS = 3;
const GAP = 2;
const TILE = (Dimensions.get('window').width - GAP * (COLUMNS + 1)) / COLUMNS;

const PAGE_SIZE = 100;

export default function SelectScreen({ navigation }: Props) {
  const [assets, setAssets] = useState<MediaAsset[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(true);
  const [endCursor, setEndCursor] = useState<string | undefined>(undefined);

  useEffect(() => { loadPage(); }, []);

  async function loadPage() {
    const result = await MediaLibrary.getAssetsAsync({
      mediaType: ['photo', 'video'],
      first: PAGE_SIZE,
      after: endCursor,
      sortBy: [MediaLibrary.SortBy.creationTime],
    });
    setAssets(prev => [...prev, ...result.assets]);
    setHasMore(result.hasNextPage);
    setEndCursor(result.endCursor);
    setLoading(false);
  }

  const toggleSelect = useCallback((id: string) => {
    setSelected(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }, []);

  const toggleAll = () => {
    if (selected.size === assets.length) {
      setSelected(new Set());
    } else {
      setSelected(new Set(assets.map(a => a.id)));
    }
  };

  const allSelected = assets.length > 0 && selected.size === assets.length;

  const proceed = () => {
    const picked = assets.filter(a => selected.has(a.id));
    navigation.navigate('Export', { selectedAssets: picked });
  };

  const renderItem = ({ item }: { item: MediaAsset }) => {
    const sel = selected.has(item.id);
    return (
      <TouchableOpacity
        style={styles.tile}
        onPress={() => toggleSelect(item.id)}
        activeOpacity={0.8}
      >
        <Image
          source={{ uri: item.uri }}
          style={styles.tileImage}
          contentFit="cover"
          transition={100}
        />
        {item.mediaType === 'video' && (
          <View style={styles.videoBadge}>
            <Ionicons name="videocam" size={12} color="#fff" />
          </View>
        )}
        <View style={[styles.checkCircle, sel && styles.checkCircleSelected]}>
          {sel && <Ionicons name="checkmark" size={14} color="#fff" />}
        </View>
        {sel && <View style={styles.tileOverlay} />}
      </TouchableOpacity>
    );
  };

  return (
    <SafeAreaView style={styles.container}>
      {/* Navbar */}
      <View style={styles.navbar}>
        <TouchableOpacity onPress={() => navigation.goBack()} style={styles.navBtn}>
          <Ionicons name="chevron-back" size={24} color="#3B82F6" />
        </TouchableOpacity>
        <Text style={styles.navTitle}>Select Photos</Text>
        <TouchableOpacity onPress={toggleAll} style={styles.navBtn}>
          <Text style={styles.navAction}>{allSelected ? 'Deselect All' : 'Select All'}</Text>
        </TouchableOpacity>
      </View>

      {/* Selection bar */}
      <View style={styles.selectionBar}>
        <Text style={styles.selectionText}>
          {selected.size === 0
            ? 'Tap to select photos'
            : `${selected.size.toLocaleString()} selected`}
        </Text>
      </View>

      {loading ? (
        <View style={styles.loader}>
          <ActivityIndicator size="large" color="#3B82F6" />
          <Text style={styles.loadingText}>Loading library…</Text>
        </View>
      ) : (
        <FlatList
          data={assets}
          keyExtractor={a => a.id}
          numColumns={COLUMNS}
          renderItem={renderItem}
          onEndReached={hasMore ? loadPage : undefined}
          onEndReachedThreshold={0.4}
          contentContainerStyle={styles.grid}
          ItemSeparatorComponent={() => <View style={{ height: GAP }} />}
          columnWrapperStyle={{ gap: GAP }}
        />
      )}

      {/* Footer CTA */}
      {selected.size > 0 && (
        <View style={styles.footer}>
          <TouchableOpacity style={styles.proceedBtn} onPress={proceed}>
            <Text style={styles.proceedText}>
              Export {selected.size.toLocaleString()} {selected.size === 1 ? 'item' : 'items'}
            </Text>
            <Ionicons name="arrow-forward" size={20} color="#fff" />
          </TouchableOpacity>
        </View>
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  navbar: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: 8, paddingVertical: 10, borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#E2E8F0',
  },
  navBtn: { padding: 8, minWidth: 80 },
  navTitle: { fontSize: 17, fontWeight: '700', color: '#1E293B' },
  navAction: { fontSize: 15, color: '#3B82F6', fontWeight: '600', textAlign: 'right' },
  selectionBar: { paddingHorizontal: 16, paddingVertical: 8, backgroundColor: '#F8FAFC' },
  selectionText: { fontSize: 13, color: '#64748B' },
  grid: { padding: GAP },
  tile: { width: TILE, height: TILE, position: 'relative', overflow: 'hidden' },
  tileImage: { width: TILE, height: TILE, backgroundColor: '#E2E8F0' },
  tileOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(59,130,246,0.25)',
  },
  checkCircle: {
    position: 'absolute', top: 6, right: 6,
    width: 22, height: 22, borderRadius: 11,
    borderWidth: 2, borderColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.2)',
  },
  checkCircleSelected: { backgroundColor: '#3B82F6', borderColor: '#3B82F6' },
  videoBadge: {
    position: 'absolute', bottom: 6, left: 6,
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 4, paddingHorizontal: 5, paddingVertical: 2,
  },
  loader: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 },
  loadingText: { color: '#64748B', fontSize: 15 },
  footer: {
    padding: 16, paddingBottom: 8,
    borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: '#E2E8F0',
    backgroundColor: '#fff',
  },
  proceedBtn: {
    backgroundColor: '#3B82F6', borderRadius: 16, padding: 18,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
  },
  proceedText: { color: '#fff', fontSize: 17, fontWeight: '700' },
});
