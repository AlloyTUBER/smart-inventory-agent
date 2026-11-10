import { useEffect, useState } from "react";
import { Routes, Route } from "react-router-dom";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Products from "./pages/Products";
import Alerts from "./pages/Alerts";
import PurchaseOrders from "./pages/PurchaseOrders";
import Login from "./pages/Login";

export default function App() {

  const [isMobile, setIsMobile] = useState(false);

  useEffect(() => {
    const userAgent = navigator.userAgent || navigator.vendor || window.opera;
    const isMobileDevice = /android|iphone|ipad|ipod/i.test(userAgent);
    
    if (isMobileDevice) {
      setIsMobile(true);
      // ❌ REMOVE window.location.href = "smartinventory://" from here
    }
  }, []);

  if (isMobile) {
    return (
      <div className="flex flex-col items-center justify-center h-screen bg-slate-900 text-white">
        <h1 className="text-2xl font-bold mb-4">Smart Inventory App</h1>
        
        {/* ✅ Add a manual button to open the app */}
        <button 
          onClick={() => window.location.href = "smartinventory://"}
          className="px-6 py-3 bg-green-600 rounded-lg font-bold mb-4 w-64">
          Open Installed App
        </button>

        <a href="/downloads/app.apk" className="px-6 py-3 bg-blue-600 rounded-lg font-bold mb-4 w-64 text-center">
          Download APK
        </a>
        
        <button onClick={() => setIsMobile(false)} className="mt-4 text-sm underline">
          Continue in browser anyway
        </button>
      </div>
    );
  }

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