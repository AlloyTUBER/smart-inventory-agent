import { View, Text, StyleSheet } from "react-native";

export default function ProductScreen({ route }) {
    const { product } = route.params;
    const low = product.stock <= product.reorderPoint;

    return (
        <View style={styles.container}>
            <View style={styles.card}>
                <Text style={styles.name}>{product.name}</Text>
                <Text style={styles.row}>Category: {product.category}</Text>
                <Text style={styles.row}>Supplier: {product.supplier}</Text>
                <Text style={styles.row}>Current stock: {product.stock}</Text>
                <Text style={styles.row}>Reorder point: {product.reorderPoint}</Text>
                <Text style={[styles.status, { color: low ? "#dc2626" : "#16a34a" }]}>
                    {low ? "Reorder needed" : "Stock level OK"}
                </Text>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: "#f3f4f6", padding: 16 },
    card: { backgroundColor: "#fff", borderRadius: 12, padding: 20 },
    name: { fontSize: 24, fontWeight: "bold", marginBottom: 12 },
    row: { fontSize: 16, marginBottom: 6 },
    status: { fontSize: 18, fontWeight: "bold", marginTop: 12 },
});