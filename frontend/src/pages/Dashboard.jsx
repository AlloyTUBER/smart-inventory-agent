import { useState, useEffect } from "react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from "recharts";
import { fetchStock } from "../api";

export default function Dashboard() {
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadData = () => {
    setLoading(true);
    fetchStock()
      .then((data) => {
        setProducts(
          data.map((p) => ({
            id: p.product_id,
            name: p.name,
            category: p.category,
            stock: Number(p.total_qty),
            reorderPoint: p.reorder_point ?? 0,
            supplier: p.supplier,
          }))
        );
        setError("");
      })
      .catch((err) => setError(err.message || "Failed to load dashboard data"))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    loadData();
  }, []);

  if (loading)
    return <p className="p-6 text-gray-500">Loading dashboard…</p>;
  if (error)
    return (
      <div className="p-6">
        <p className="text-red-600 mb-3">{error}</p>
        <button
          onClick={loadData}
          className="bg-blue-600 text-white px-4 py-2 rounded-lg text-sm"
        >
          Retry
        </button>
      </div>
    );

  const lowStock = products.filter((p) => p.stock <= p.reorderPoint);

  const cards = [
    { label: "Total Products", value: products.length },
    { label: "Low Stock Items", value: lowStock.length },
    {
      label: "Total Units",
      value: products.reduce((sum, p) => sum + p.stock, 0),
    },
  ];

  return (
    <div>
      <div className="flex justify-between items-center mb-6">
        <h2 className="text-2xl font-bold">Dashboard</h2>
        <button
          onClick={loadData}
          className="text-sm bg-gray-200 hover:bg-gray-300 px-3 py-1.5 rounded-lg text-gray-700"
        >
          🔄 Refresh
        </button>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6">
        {cards.map((c) => (
          <div key={c.label} className="bg-white rounded-xl p-5 shadow">
            <p className="text-gray-500 text-sm">{c.label}</p>
            <p className="text-3xl font-bold mt-1">{c.value}</p>
          </div>
        ))}
      </div>

      <div className="bg-white rounded-xl p-5 shadow mb-6">
        <h3 className="font-semibold mb-4">Stock vs Reorder Point (Top 15 Items)</h3>
        <div style={{ width: "100%", height: 320 }}>
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={products.slice(0, 15)}>
              <XAxis dataKey="name" interval={0} angle={-25} textAnchor="end" height={60} tick={{ fontSize: 12 }} />
              <YAxis />
              <Tooltip />
              <Legend verticalAlign="top" />
              <Bar dataKey="stock" fill="#2563eb" name="Current Stock" />
              <Bar dataKey="reorderPoint" fill="#f59e0b" name="Reorder Point" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="bg-white rounded-xl p-5 shadow">
        <h3 className="font-semibold mb-3">Low Stock Alerts</h3>
        {lowStock.length === 0 && (
          <p className="text-green-600">All stock levels are healthy!</p>
        )}
        {lowStock.map((p) => (
          <p key={p.id} className="py-1 text-red-600 text-sm">
            <span className="font-medium">{p.name}</span>: only {p.stock} left (reorder at {p.reorderPoint})
            {p.supplier ? ` • Supplier: ${p.supplier}` : ""}
          </p>
        ))}
      </div>
    </div>
  );
}
