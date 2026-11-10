import { useState } from "react";
import { Routes, Route } from "react-router-dom";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Products from "./pages/Products";
import Alerts from "./pages/Alerts";
import PurchaseOrders from "./pages/PurchaseOrders";
import Login from "./pages/Login";

// 1. Synchronous detection outside the component prevents the "flash"
const checkMobile = () => {
  if (typeof navigator === "undefined") return false;
  return /android|iphone|ipad|ipod/i.test(navigator.userAgent || navigator.vendor);
};

export default function App() {
  // 2. Initialize state immediately with the device check
  const [showMobilePrompt, setShowMobilePrompt] = useState(checkMobile());
  
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

  const handleOpenApp = () => {
    // Deep link is now strictly bound to the button click to prevent browser crashing
    window.location.href = "smartinventory://";
  };

  // 3. Render the Mobile Intercept Wall
  if (showMobilePrompt) {
    return (
      <div className="flex flex-col items-center justify-center h-screen bg-slate-900 text-white">
        <h1 className="text-2xl font-bold mb-4">Smart Inventory App</h1>
        <p className="mb-6">For the best experience, use our native mobile app.</p>
        
        <button 
          onClick={handleOpenApp}
          className="px-6 py-3 bg-green-600 rounded-lg font-bold mb-4 w-64">
          Open Installed App
        </button>

        <a href="/downloads/app.apk" className="px-6 py-3 bg-blue-600 rounded-lg font-bold mb-4 w-64 text-center">
          Download APK
        </a>
        
        <button onClick={() => setShowMobilePrompt(false)} className="mt-4 text-sm underline hover:text-gray-300">
          Continue in browser anyway
        </button>
      </div>
    );
  }

  // 4. Render the Web Application
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