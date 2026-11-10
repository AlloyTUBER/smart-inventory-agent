import { View, Text, Button, StyleSheet } from 'react-native';
import { useRouter } from 'expo-router';

export default function LoginScreen() {
  const router = useRouter();
  
  const handleLogin = () => {
    // Make sure THIS is the only thing inside this function.
    // If you have onLogin() here, delete it!
    router.replace('/stock');
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Smart Inventory</Text>
      <Button title="Sign In" onPress={handleLogin} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  title: { fontSize: 24, marginBottom: 20, fontWeight: 'bold' }
});