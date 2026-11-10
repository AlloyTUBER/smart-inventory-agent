import { useState } from "react";
import { Routes, Route } from "react-router-dom";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Products from "./pages/Products";
import Alerts from "./pages/Alerts";
import PurchaseOrders from "./pages/PurchaseOrders";
import Login from "./pages/Login";

export default function App() {
  const [loggedIn, setLoggedIn] = useState(
    localStorage.getItem("loggedIn") === "true"
  );

  const handleLogin = () => {
    localStorage.setItem("loggedIn", "true");
    setLoggedIn(true);
  };

  const handleLogout = () => {
    localStorage.removeItem("loggedIn");
    setLoggedIn(false);
  };

  if (!loggedIn) return <Login onLogin={handleLogin} />;

  return (
    <Routes>
      <Route element={<Layout onLogout={handleLogout} />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/products" element={<Products />} />
        <Route path="/alerts" element={<Alerts />} />
        <Route path="/orders" element={<PurchaseOrders />} />
      </Route>
    </Routes>
  );
}