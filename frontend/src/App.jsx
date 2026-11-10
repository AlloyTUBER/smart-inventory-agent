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
    // 1. Detect if the user's device is a mobile phone
    const userAgent = navigator.userAgent || navigator.vendor || window.opera;
    const isMobileDevice = /android|iphone|ipad|ipod/i.test(userAgent);
    
    if (isMobileDevice) {
      setIsMobile(true);
      
      // 2. Attempt to open the Native Expo App via Deep Link
      // If they have the APK installed, it opens. If not, it falls back.
      window.location.href = "smartinventory://"; 
    }
  }, []);

  // 3. Render a download prompt for mobile users, or the full web UI for PC users
  if (isMobile) {
    return (
      <div className="flex flex-col items-center justify-center h-screen bg-slate-900 text-white">
        <h1 className="text-2xl font-bold mb-4">Smart Inventory App</h1>
        <p className="mb-6">For the best experience, use our native mobile app.</p>
        <a href="/downloads/app.apk" className="px-6 py-3 bg-blue-600 rounded-lg font-bold">
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