import { useEffect, useState } from 'react';
import { View, Text, FlatList, ActivityIndicator, StyleSheet } from 'react-native';
import api from '../utils/api'; // Your configured Axios instance

export default function StockScreen() {
  const [inventory, setInventory] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchLiveInventory = async () => {
      try {
        // Fetches directly from your FastAPI PostgreSQL database
        const response = await api.get('/products'); 
        setInventory(response.data);
      } catch (error) {
        console.error("Database fetch error:", error);
      } finally {
        setLoading(false);
      }
    };
    fetchLiveInventory();
  }, []);

  if (loading) return <ActivityIndicator size="large" style={{flex: 1}} />;

  return (
    <View style={styles.container}>
      <FlatList 
        data={inventory}
        keyExtractor={(item) => String(item.product_id)}
        renderItem={({ item }) => (
          <View style={styles.card}>
            <Text style={styles.name}>{item.name}</Text>
            <Text>Stock: {item.stock} | Reorder: {item.reorder_point}</Text>
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 16, backgroundColor: '#f3f4f6' },
  card: { padding: 16, backgroundColor: '#fff', marginBottom: 8, borderRadius: 8 }
});