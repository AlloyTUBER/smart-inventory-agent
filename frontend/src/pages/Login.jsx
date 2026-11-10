import { useState } from "react";
import { login } from "../api";

export default function Login({ onLogin }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleLogin = async (e) => {
    if (e) e.preventDefault();
    setError("");
    setLoading(true);

    try {
      const res = await login(email, password);
      if (res && res.user) {
        localStorage.setItem("user", JSON.stringify(res.user));
      }
      onLogin();
    } catch (err) {
      // Allow demo login fallback if offline or backend error with valid demo credentials
      if (
        (email.trim().toLowerCase() === "admin@inventory.com" ||
          email.trim().toLowerCase() === "admin@inventory.example") &&
        password === "admin123"
      ) {
        localStorage.setItem(
          "user",
          JSON.stringify({ name: "Admin User", email, role: "admin" })
        );
        onLogin();
      } else {
        setError(
          err.response?.data?.detail ||
            err.message ||
            "Invalid email or password"
        );
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-100 px-4">
      <div className="bg-white p-8 rounded-2xl shadow-lg w-full max-w-md border border-gray-100">
        <div className="flex items-center gap-3 mb-2">
          <div className="w-10 h-10 rounded-xl bg-blue-600 text-white flex items-center justify-center font-bold text-xl">
            📦
          </div>
          <h1 className="text-2xl font-bold text-gray-900">Smart Inventory</h1>
        </div>
        <p className="text-gray-500 mb-6 text-sm">
          Sign in to access your inventory control dashboard
        </p>

        <form onSubmit={handleLogin}>
          <div className="mb-3">
            <label className="block text-xs font-semibold text-gray-700 uppercase mb-1">
              Email
            </label>
            <input
              type="email"
              required
              className="border border-gray-300 rounded-lg px-3 py-2 w-full text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              placeholder="admin@inventory.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>

          <div className="mb-4">
            <label className="block text-xs font-semibold text-gray-700 uppercase mb-1">
              Password
            </label>
            <input
              type="password"
              required
              className="border border-gray-300 rounded-lg px-3 py-2 w-full text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>

          {error && (
            <div className="text-red-600 bg-red-50 p-2.5 rounded-lg text-sm mb-4 border border-red-200">
              {error}
            </div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white w-full py-2.5 rounded-lg font-medium text-sm transition"
          >
            {loading ? "Signing in…" : "Sign In"}
          </button>
        </form>

        <div className="mt-6 pt-4 border-t border-gray-100 text-xs text-gray-500">
          <p className="font-semibold text-gray-700 mb-1">Demo Credentials:</p>
          <p>
            Email: <code className="bg-gray-100 px-1 py-0.5 rounded">admin@inventory.com</code>
          </p>
          <p>
            Password: <code className="bg-gray-100 px-1 py-0.5 rounded">admin123</code>
          </p>
        </div>
      </div>
    </div>
  );
}
