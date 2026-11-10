import { useState } from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import LoginScreen from "./screens/LoginScreen";
import StockListScreen from "./screens/StockListScreen";
import ProductScreen from "./screens/ProductScreen";
import AlertsScreen from "./screens/AlertsScreen";

const Stack = createNativeStackNavigator();

export default function App() {
  const [loggedIn, setLoggedIn] = useState(false);

  return (
    <NavigationContainer>
      <Stack.Navigator>
        {!loggedIn ? (
          <Stack.Screen name="Login" options={{ headerShown: false }}>
            {() => <LoginScreen onLogin={() => setLoggedIn(true)} />}
          </Stack.Screen>
        ) : (
          <>
            <Stack.Screen name="Stock" component={StockListScreen} options={{ title: "Smart Inventory" }} />
            <Stack.Screen name="Product" component={ProductScreen} options={{ title: "Product Details" }} />
            <Stack.Screen name="Alerts" component={AlertsScreen} options={{ title: "Alerts" }} />
          </>
        )}
      </Stack.Navigator>
    </NavigationContainer>
  );
}