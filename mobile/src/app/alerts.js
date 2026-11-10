import { View, Text, FlatList, StyleSheet } from "react-native";
import { products } from "../../data/mockProducts";

export default function AlertsScreen() {
    const lowStock = products.filter((p) => p.stock <= p.reorderPoint);

    return (
        <View style={styles.container}>
            {lowStock.length === 0 && <Text>No alerts right now.</Text>}
            <FlatList
                data={lowStock}
                keyExtractor={(item) => String(item.id)}
                renderItem={({ item }) => (
                    <View style={styles.card}>
                        <Text style={styles.name}>{item.name} is running low</Text>
                        <Text style={styles.meta}>
                            {item.stock} left, reorder point {item.reorderPoint}. Supplier: {item.supplier}
                        </Text>
                    </View>
                )}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: "#f3f4f6", padding: 16 },
    card: { backgroundColor: "#fff", borderLeftWidth: 4, borderLeftColor: "#ef4444", borderRadius: 10, padding: 14, marginBottom: 10 },
    name: { fontWeight: "600", fontSize: 16 },
    meta: { color: "#6b7280", marginTop: 4 },
});