const path = require('path');
const { minimumVisualDistance, SUPPORTED_EXTENSIONS } = require('./visual-hash');

const SAME_IMAGE_DISTANCE = 4;
const SIMILAR_IMAGE_DISTANCE = 10;
const EDITED_IMAGE_DISTANCE = 14;
const BURST_IMAGE_DISTANCE = 14;
const TEN_MINUTES_MS = 10 * 60 * 1000;
const FIFTEEN_SECONDS_MS = 15 * 1000;

const EDIT_MARKER = /(?:^|[\s._-])(?:edited|edit|exported|export|compressed|optimized|converted|enhanced|filtered|retouched)(?:[\s._-]*\d+)?(?:$|[\s._-])/i;

function normalizedStem(filename) {
  let stem = path.basename(filename, path.extname(filename)).normalize('NFKC').toLowerCase().trim();
  const suffix = /(?:[\s._-]+(?:copy|duplicate|duplicated|dup|edited|edit|exported|export|compressed|optimized|converted|backup)(?:[\s._-]*\d+)?|\s*\(\d+\))+$/i;
  let previous;
  do {
    previous = stem;
    stem = stem.replace(suffix, '').trim();
  } while (stem !== previous);
  return stem;
}

function hasEditMarker(filename) {
  const stem = path.basename(filename, path.extname(filename)).normalize('NFKC').toLowerCase();
  return EDIT_MARKER.test(stem);
}

function sequenceInfo(filename) {
  const stem = path.basename(filename, path.extname(filename)).normalize('NFKC').toLowerCase().trim();
  const match = stem.match(/^(.*?)(\d{2,})$/);
  if (!match) return null;
  return { prefix: match[1], number: Number(match[2]) };
}

function isLikelyBurst(a, b, dateDifference, visualDistance) {
  if (dateDifference == null || dateDifference > FIFTEEN_SECONDS_MS) return false;
  if (visualDistance == null || visualDistance > BURST_IMAGE_DISTANCE) return false;
  if (hasEditMarker(a.name || '') || hasEditMarker(b.name || '')) return false;
  const left = sequenceInfo(a.name || '');
  const right = sequenceInfo(b.name || '');
  return left != null && right != null && left.prefix === right.prefix
    && left.number !== right.number && Math.abs(left.number - right.number) <= 20;
}

function isPhoto(file) {
  return SUPPORTED_EXTENSIONS.has((file.ext || path.extname(file.name || '')).toLowerCase());
}

function numericDate(file) {
  if (!file.date) return null;
  const value = new Date(file.date).getTime();
  return Number.isFinite(value) ? value : null;
}

function aspectRatio(file) {
  return file.pixelWidth > 0 && file.pixelHeight > 0 ? file.pixelWidth / file.pixelHeight : null;
}

function relativeDifference(left, right) {
  const larger = Math.max(left || 0, right || 0);
  return larger > 0 ? Math.abs(left - right) / larger : 1;
}

function orientationAwareAspectDifference(left, right) {
  if (!(left > 0 && right > 0)) return 0;
  return Math.min(relativeDifference(left, right), relativeDifference(1 / left, right));
}

function candidatePairs(files) {
  const pairs = new Map();
  const add = (a, b) => {
    if (a === b) return;
    const left = Math.min(a, b), right = Math.max(a, b);
    pairs.set(`${left}:${right}`, [left, right]);
  };

  const byStem = new Map();
  files.forEach((file, index) => {
    const stem = normalizedStem(file.name || '');
    if (!stem) return;
    if (!byStem.has(stem)) byStem.set(stem, []);
    byStem.get(stem).push(index);
  });
  for (const group of byStem.values()) {
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < Math.min(group.length, i + 100); j++) add(group[i], group[j]);
    }
  }

  const dated = files.map((file, index) => ({ index, date: numericDate(file), aspect: aspectRatio(file) }))
    .filter(item => item.date != null && item.aspect != null)
    .sort((a, b) => a.date - b.date);
  for (let i = 0; i < dated.length; i++) {
    for (let j = i + 1; j < Math.min(dated.length, i + 100) && dated[j].date - dated[i].date <= TEN_MINUTES_MS; j++) {
      if (orientationAwareAspectDifference(dated[i].aspect, dated[j].aspect) <= 0.08) add(dated[i].index, dated[j].index);
    }
  }

  const byDimensions = new Map();
  files.forEach((file, index) => {
    if (!(file.pixelWidth > 0 && file.pixelHeight > 0)) return;
    const key = `${Math.min(file.pixelWidth, file.pixelHeight)}x${Math.max(file.pixelWidth, file.pixelHeight)}`;
    if (!byDimensions.has(key)) byDimensions.set(key, []);
    byDimensions.get(key).push(index);
  });
  for (const group of byDimensions.values()) {
    group.sort((a, b) => files[a].size - files[b].size);
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < Math.min(group.length, i + 7); j++) {
        if (relativeDifference(files[group[i]].size, files[group[j]].size) <= 0.15) add(group[i], group[j]);
      }
    }
  }

  return Array.from(pairs.values());
}

function visualCandidateIndexes(files) {
  const result = new Set();
  for (const [left, right] of candidatePairs(files)) {
    result.add(left);
    result.add(right);
  }
  return result;
}

function electOriginal(files) {
  const rank = file => {
    let value = 0;
    if (!file.archiveSourcePath) value += 10_000;
    if (file.date && file.dateSource !== 'filename') value += 1_000;
    if (file.latitude != null && file.longitude != null) value += 200;
    value += Math.min((file.pixelWidth || 0) * (file.pixelHeight || 0) / 1_000_000, 100);
    value += Math.min((file.size || 0) / 10_000_000, 10);
    value -= String(file.path || '').split(/[\\/]/).length;
    return value;
  };
  return [...files].sort((a, b) => rank(b) - rank(a))[0];
}

function markExactDuplicates(files) {
  for (const file of files) {
    file.isDuplicate = false;
    file.duplicateOf = null;
    file.duplicateGroupID = null;
  }
  const byHash = new Map();
  for (const file of files) {
    if (!file.hash) continue;
    if (!byHash.has(file.hash)) byHash.set(file.hash, []);
    byHash.get(file.hash).push(file);
  }
  let groups = 0;
  for (const group of byHash.values()) {
    if (group.length < 2) continue;
    groups++;
    const original = electOriginal(group);
    const groupID = `exact-${groups}`;
    for (const file of group) {
      file.duplicateGroupID = groupID;
      if (file === original) continue;
      file.isDuplicate = true;
      file.duplicateOf = original.id;
    }
  }
  return groups;
}

class UnionFind {
  constructor(size) { this.parent = Array.from({ length: size }, (_, index) => index); }
  find(value) {
    while (this.parent[value] !== value) {
      this.parent[value] = this.parent[this.parent[value]];
      value = this.parent[value];
    }
    return value;
  }
  union(left, right) {
    const a = this.find(left), b = this.find(right);
    if (a !== b) this.parent[b] = a;
  }
}

function metadataScore(a, b) {
  let score = normalizedStem(a.name) === normalizedStem(b.name) ? 50 : 0;
  const reasons = score ? ['Related filename'] : [];
  const sizeRatio = relativeDifference(a.size, b.size);
  if (sizeRatio <= 0.01) { score += 25; reasons.push('Size within 1%'); }
  else if (sizeRatio <= 0.03) { score += 10; reasons.push('Size within 3%'); }
  const leftDate = numericDate(a), rightDate = numericDate(b);
  if (leftDate != null && rightDate != null) {
    const difference = Math.abs(leftDate - rightDate);
    if (difference <= 5 * 60 * 1000) { score += 20; reasons.push('Capture time within 5 min'); }
    else if (difference <= 60 * 60 * 1000) { score += 17; reasons.push('Capture time within 1 hour'); }
    else if (difference <= 24 * 60 * 60 * 1000) { score += 10; reasons.push('Capture time within 24 hours'); }
  }
  if (a.pixelWidth > 0 && a.pixelHeight > 0 && a.pixelWidth === b.pixelWidth && a.pixelHeight === b.pixelHeight) {
    score += 10;
    reasons.push(`Dimensions ${a.pixelWidth}×${a.pixelHeight}`);
  }
  return { score: Math.min(score, 100), reasons };
}

function classifyPair(a, b) {
  const visualDistance = minimumVisualDistance(a.visualHashes, b.visualHashes);
  const metadata = metadataScore(a, b);
  const leftDate = numericDate(a), rightDate = numericDate(b);
  const dateDifference = leftDate != null && rightDate != null ? Math.abs(leftDate - rightDate) : null;
  const sameStem = normalizedStem(a.name) === normalizedStem(b.name);
  const sameDimensions = a.pixelWidth > 0 && a.pixelHeight > 0
    && ((a.pixelWidth === b.pixelWidth && a.pixelHeight === b.pixelHeight)
      || (a.pixelWidth === b.pixelHeight && a.pixelHeight === b.pixelWidth));
  const leftAspect = aspectRatio(a), rightAspect = aspectRatio(b);
  const aspectDifference = orientationAwareAspectDifference(leftAspect, rightAspect);
  const editedVersion = hasEditMarker(a.name || '') || hasEditMarker(b.name || '');

  if (visualDistance != null && visualDistance <= EDITED_IMAGE_DISTANCE && aspectDifference <= 0.18
      && editedVersion && (sameStem || (dateDifference != null && dateDifference <= 24 * 60 * 60 * 1000))) {
    return {
      kind: 'edited',
      score: Math.max(78, 94 - visualDistance),
      reasons: `Edited version · visual distance ${visualDistance}/64 · review only`,
    };
  }
  if (isLikelyBurst(a, b, dateDifference, visualDistance) && aspectDifference <= 0.08) {
    return {
      kind: 'burst',
      score: Math.max(78, 92 - visualDistance),
      reasons: `Burst sequence · ${Math.round(dateDifference / 1000)}s apart · review only`,
    };
  }

  if (visualDistance != null && visualDistance <= SAME_IMAGE_DISTANCE && aspectDifference <= 0.03
      && (sameStem || sameDimensions || (dateDifference != null && dateDifference <= 24 * 60 * 60 * 1000))) {
    return {
      kind: 'same',
      score: Math.max(94, 100 - visualDistance),
      reasons: `Visual match · distance ${visualDistance}/64${sameDimensions ? ' · same dimensions' : ''}`,
    };
  }
  if (visualDistance != null && visualDistance <= SIMILAR_IMAGE_DISTANCE && aspectDifference <= 0.05
      && (sameStem || (dateDifference != null && dateDifference <= TEN_MINUTES_MS))) {
    return {
      kind: sameStem ? 'edited' : 'similar',
      score: Math.max(80, 92 - visualDistance),
      reasons: `${sameStem ? 'Possible edited version' : 'Visually similar'} · distance ${visualDistance}/64 · review only`,
    };
  }
  if (visualDistance == null && metadata.score >= 90) {
    return {
      kind: 'similar',
      score: Math.min(89, metadata.score - 5),
      reasons: `${metadata.reasons.join(' · ')} · visual check unavailable · review only`,
    };
  }
  return null;
}

function detectSmartDuplicates(files) {
  const candidates = files.filter(file => !file.isDuplicate && isPhoto(file));
  for (const file of candidates) {
    file.isProbableDuplicate = false;
    file.probableDuplicateGroupID = null;
    file.probableMatchScore = 0;
    file.probableMatchReasons = null;
    file.probableMatchPeerFilename = null;
    file.probableMatchKind = null;
  }

  const allGroups = new UnionFind(candidates.length);
  const sameGroups = new UnionFind(candidates.length);
  const edges = [];
  for (const [left, right] of candidatePairs(candidates)) {
    const match = classifyPair(candidates[left], candidates[right]);
    if (!match) continue;
    edges.push({ left, right, ...match });
    allGroups.union(left, right);
    if (match.kind === 'same') sameGroups.union(left, right);
  }

  const components = new Map();
  edges.forEach(edge => {
    const root = allGroups.find(edge.left);
    if (!components.has(root)) components.set(root, { indexes: new Set(), edges: [] });
    components.get(root).indexes.add(edge.left);
    components.get(root).indexes.add(edge.right);
    components.get(root).edges.push(edge);
  });

  let groupNumber = 0;
  for (const component of components.values()) {
    groupNumber++;
    const groupID = `smart-${groupNumber}`;
    for (const index of component.indexes) candidates[index].probableDuplicateGroupID = groupID;

    const bestEdgeByIndex = new Map();
    for (const edge of component.edges) {
      for (const index of [edge.left, edge.right]) {
        if (!bestEdgeByIndex.has(index) || bestEdgeByIndex.get(index).score < edge.score) bestEdgeByIndex.set(index, edge);
      }
    }
    for (const [index, edge] of bestEdgeByIndex) {
      const peerIndex = edge.left === index ? edge.right : edge.left;
      candidates[index].probableMatchScore = edge.score;
      candidates[index].probableMatchReasons = edge.reasons;
      candidates[index].probableMatchPeerFilename = candidates[peerIndex].name;
      candidates[index].probableMatchKind = edge.kind;
    }

    const highComponents = new Map();
    for (const index of component.indexes) {
      const root = sameGroups.find(index);
      if (!highComponents.has(root)) highComponents.set(root, []);
      highComponents.get(root).push(candidates[index]);
    }
    for (const group of highComponents.values()) {
      if (group.length < 2) continue;
      const original = electOriginal(group);
      for (const file of group) {
        file.probableMatchKind = 'same';
        if (file === original) continue;
        file.isProbableDuplicate = true;
        file.probableMatchPeerFilename = original.name;
      }
    }
  }

  return { groups: components.size, matchedFiles: candidates.filter(file => file.probableDuplicateGroupID).length };
}

module.exports = {
  normalizedStem,
  candidatePairs,
  visualCandidateIndexes,
  classifyPair,
  detectSmartDuplicates,
  markExactDuplicates,
  electOriginal,
  SAME_IMAGE_DISTANCE,
  SIMILAR_IMAGE_DISTANCE,
  EDITED_IMAGE_DISTANCE,
  BURST_IMAGE_DISTANCE,
  hasEditMarker,
  sequenceInfo,
  isLikelyBurst,
  orientationAwareAspectDifference,
};
