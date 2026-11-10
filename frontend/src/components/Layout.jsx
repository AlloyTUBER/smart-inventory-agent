import { NavLink, Outlet } from "react-router-dom";

const linkClass = ({ isActive }) =>
  `block px-4 py-2.5 rounded-lg mb-1 font-medium text-sm transition ${
    isActive ? "bg-blue-600 text-white shadow-sm" : "text-gray-300 hover:bg-gray-800 hover:text-white"
  }`;

export default function Layout({ onLogout }) {
  const user = (() => {
    try {
      return JSON.parse(localStorage.getItem("user") || "null");
    } catch {
      return null;
    }
  })();

  return (
    <div className="flex min-h-screen bg-gray-100">
      <aside className="w-64 bg-gray-900 p-4 flex flex-col shrink-0">
        <div className="flex items-center gap-2 mb-8 px-2 pt-2">
          <span className="text-2xl">📦</span>
          <div>
            <h1 className="text-white text-lg font-bold leading-tight">Smart Inventory</h1>
            <p className="text-xs text-blue-400 font-mono">Autonomous Agent v2.0</p>
          </div>
        </div>

        <nav className="flex-1 space-y-1">
          <NavLink to="/" end className={linkClass}>
            📊 Dashboard
          </NavLink>
          <NavLink to="/products" className={linkClass}>
            🏷️ Products
          </NavLink>
          <NavLink to="/alerts" className={linkClass}>
            🔔 Alerts
          </NavLink>
          <NavLink to="/orders" className={linkClass}>
            📋 Purchase Orders
          </NavLink>
        </nav>

        <div className="mt-auto pt-4 border-t border-gray-800">
          {user && (
            <div className="px-3 py-2 mb-2 text-xs text-gray-400">
              <p className="font-semibold text-gray-200">{user.name || "Logged User"}</p>
              <p className="truncate">{user.email || ""}</p>
            </div>
          )}
          <button
            onClick={onLogout}
            className="w-full text-left px-4 py-2 rounded-lg text-sm text-gray-400 hover:text-red-400 hover:bg-gray-800 transition"
          >
            ← Logout
          </button>
        </div>
      </aside>
      <main className="flex-1 p-8 overflow-y-auto max-h-screen">
        <Outlet />
      </main>
    </div>
  );
}
