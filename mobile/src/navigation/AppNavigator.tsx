import React from 'react';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import HomeScreen from '../screens/HomeScreen';
import SelectScreen from '../screens/SelectScreen';
import ExportScreen from '../screens/ExportScreen';
import ProgressScreen from '../screens/ProgressScreen';
import { MediaAsset, ExportConfig } from '../utils/types';

export type RootStackParamList = {
  Home: undefined;
  Select: undefined;
  Export: { selectedAssets: MediaAsset[] };
  Progress: { selectedAssets: MediaAsset[]; config: ExportConfig };
};

const Stack = createNativeStackNavigator<RootStackParamList>();

export default function AppNavigator() {
  return (
    <Stack.Navigator
      screenOptions={{
        headerShown: false,
        animation: 'slide_from_right',
      }}
    >
      <Stack.Screen name="Home" component={HomeScreen} />
      <Stack.Screen name="Select" component={SelectScreen} />
      <Stack.Screen name="Export" component={ExportScreen} />
      <Stack.Screen name="Progress" component={ProgressScreen} />
    </Stack.Navigator>
  );
}
