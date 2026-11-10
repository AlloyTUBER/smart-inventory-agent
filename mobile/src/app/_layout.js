// src/app/_layout.js
import { Stack } from 'expo-router';

export default function Layout() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ headerShown: false }} />
      <Stack.Screen name="stock" options={{ title: "Smart Inventory" }} />
      <Stack.Screen name="product" options={{ title: "Product Details" }} />
      <Stack.Screen name="alerts" options={{ title: "Alerts" }} />
    </Stack>
  );
}