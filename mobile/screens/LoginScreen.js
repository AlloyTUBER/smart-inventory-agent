import { useState } from "react";
import { View, Text, TextInput, TouchableOpacity, StyleSheet } from "react-native";

export default function LoginScreen({ onLogin }) {
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [error, setError] = useState("");

    const handleLogin = () => {
        // Temporary mock login. We'll replace it with the real backend API later.
        if (email === "admin@inventory.com" && password === "admin123") {
            onLogin();
        } else {
            setError("Invalid email or password");
        }
    };

    return (
        <View style={styles.container}>
            <Text style={styles.title}>Smart Inventory</Text>
            <Text style={styles.subtitle}>Sign in to continue</Text>

            <TextInput
                style={styles.input}
                placeholder="Email"
                autoCapitalize="none"
                value={email}
                onChangeText={setEmail}
            />
            <TextInput
                style={styles.input}
                placeholder="Password"
                secureTextEntry
                value={password}
                onChangeText={setPassword}
            />

            {error ? <Text style={styles.error}>{error}</Text> : null}

            <TouchableOpacity style={styles.button} onPress={handleLogin}>
                <Text style={styles.buttonText}>Login</Text>
            </TouchableOpacity>
            <Text style={styles.hint}>Demo login: admin@inventory.com / admin123</Text>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, justifyContent: "center", padding: 24, backgroundColor: "#f3f4f6" },
    title: { fontSize: 28, fontWeight: "bold" },
    subtitle: { color: "#6b7280", marginBottom: 24 },
    input: { backgroundColor: "#fff", borderWidth: 1, borderColor: "#d1d5db", borderRadius: 10, padding: 12, marginBottom: 12 },
    error: { color: "#dc2626", marginBottom: 12 },
    button: { backgroundColor: "#2563eb", padding: 14, borderRadius: 10, alignItems: "center" },
    buttonText: { color: "#fff", fontWeight: "600" },
    hint: { color: "#9ca3af", fontSize: 12, marginTop: 16 },
});