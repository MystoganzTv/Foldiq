/**
 * Lightweight icon component — pure Unicode/emoji, no native font loader needed.
 * Drop-in replacement for @expo/vector-icons Ionicons.
 */

import React from 'react';
import { Text, TextStyle } from 'react-native';

const ICONS: Record<string, string> = {
  // Navigation
  'chevron-back':    '‹',
  'chevron-forward': '›',
  'chevron-up':      '⌃',
  'chevron-down':    '⌄',
  'arrow-forward':   '→',
  'arrow-back':      '←',

  // Actions / Status
  'checkmark':                '✓',
  'checkmark-circle':         '✓',
  'checkmark-circle-outline': '✓',
  'download':          '↓',
  'download-outline':  '↓',
  'cloud-upload-outline': '↑',

  // Media
  'images':              '🖼',
  'images-outline':      '🖼',
  'image-outline':       '🖼',
  'videocam':            '▶',
  'videocam-outline':    '▶',
  'calendar-outline':    '📅',

  // Places / objects
  'folder-open':            '📂',
  'folder-outline':         '📁',
  'phone-portrait-outline': '📱',
  'cloud-outline':          '☁',
  'cube-outline':           '▪',
  'home-outline':           '⌂',

  // Brands (single-letter fallbacks)
  'logo-google':  'G',
};

interface Props {
  name: string;
  size?: number;
  color?: string;
  style?: TextStyle;
}

export default function Icon({ name, size = 20, color = '#000', style }: Props) {
  const glyph = ICONS[name] ?? '•';
  return (
    <Text
      style={[
        {
          fontSize: size,
          color,
          lineHeight: size * 1.2,
          textAlign: 'center',
          includeFontPadding: false,
        },
        style,
      ]}
      allowFontScaling={false}
    >
      {glyph}
    </Text>
  );
}
