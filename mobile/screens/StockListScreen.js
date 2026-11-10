import { useState } from "react";
import { View, Text, TextInput, FlatList, TouchableOpacity, StyleSheet } from "react-native";
import { products } from "../data/mockProducts";

export default function StockListScreen({ navigation }) {
    const [search, setSearch] = useState("");
    const filtered = products.filter((p) =>
        p.name.toLowerCase().includes(search.toLowerCase())
    );
    const lowCount = products.filter((p) => p.stock <= p.reorderPoint).length;

    return (
        <View style={styles.container}>
            <TouchableOpacity style={styles.alertBanner} onPress={() => navigation.navigate("Alerts")}>
                <Text style={styles.alertText}>{lowCount} items are low on stock. Tap to view</Text>
            </TouchableOpacity>

            <TextInput
                style={styles.search}
                placeholder="Search products..."
                value={search}
                onChangeText={setSearch}
            />

            <FlatList
                data={filtered}
                keyExtractor={(item) => String(item.id)}
                renderItem={({ item }) => {
                    const low = item.stock <= item.reorderPoint;
                    return (
                        <TouchableOpacity
                            style={styles.card}
                            onPress={() => navigation.navigate("Product", { product: item })}
                        >
                            <View>
                                <Text style={styles.name}>{item.name}</Text>
                                <Text style={styles.meta}>{item.category}</Text>
                            </View>
                            <View style={{ alignItems: "flex-end" }}>
                                <Text style={styles.stock}>{item.stock}</Text>
                                <Text style={{ color: low ? "#dc2626" : "#16a34a", fontSize: 12 }}>
                                    {low ? "Reorder" : "OK"}
                                </Text>
                            </View>
                        </TouchableOpacity>
                    );
                }}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: "#f3f4f6", padding: 16 },
    alertBanner: { backgroundColor: "#fee2e2", padding: 12, borderRadius: 10, marginBottom: 12 },
    alertText: { color: "#b91c1c", fontWeight: "600" },
    search: { backgroundColor: "#fff", borderWidth: 1, borderColor: "#d1d5db", borderRadius: 10, padding: 10, marginBottom: 12 },
    card: { backgroundColor: "#fff", borderRadius: 10, padding: 14, marginBottom: 10, flexDirection: "row", justifyContent: "space-between" },
    name: { fontWeight: "600", fontSize: 16 },
    meta: { color: "#6b7280", fontSize: 13 },
    stock: { fontSize: 20, fontWeight: "bold" },
});