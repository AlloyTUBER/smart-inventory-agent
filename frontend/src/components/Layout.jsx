import { useState } from 'react';
import { Outlet, Link } from 'react-router-dom';

export default function Layout({ onLogout }) {
  const [isMenuOpen, setIsMenuOpen] = useState(false);

  return (
    <div className="flex flex-col md:flex-row min-h-screen bg-slate-50">
      
      {/* Mobile Header bar */}
      <div className="md:hidden flex items-center justify-between bg-slate-900 p-4 text-white">
        <span className="font-bold text-lg">Smart Inventory</span>
        <button 
          onClick={() => setIsMenuOpen(!isMenuOpen)} 
          className="p-2 focus:outline-none text-2xl">
          ☰
        </button>
      </div>

      {/* Dynamic Sidebar */}
      <aside className={`${isMenuOpen ? 'flex' : 'hidden'} md:flex flex-col w-full md:w-64 bg-slate-900 text-white p-6 md:min-h-screen`}>
        <div className="hidden md:block font-bold text-xl mb-8">Smart Inventory</div>
        <nav className="flex flex-col gap-6 flex-grow">
          <Link to="/" onClick={() => setIsMenuOpen(false)} className="hover:text-blue-400">Dashboard</Link>
          <Link to="/products" onClick={() => setIsMenuOpen(false)} className="hover:text-blue-400">Products</Link>
          <Link to="/alerts" onClick={() => setIsMenuOpen(false)} className="hover:text-blue-400">Alerts</Link>
          <Link to="/orders" onClick={() => setIsMenuOpen(false)} className="hover:text-blue-400">Purchase Orders</Link>
        </nav>
        <button onClick={onLogout} className="mt-8 md:mt-auto text-left text-red-400 hover:text-red-300">
          Logout
        </button>
      </aside>

      {/* Main Content Area */}
      <main className="flex-1 p-4 md:p-8 w-full overflow-x-hidden">
        <Outlet />
      </main>
    </div>
  );
}