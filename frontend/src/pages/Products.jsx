import { useState, useEffect } from "react";
import { fetchProducts } from "../api";

export default function Products() {
  const [products, setProducts] = useState([]);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadProducts = () => {
    setLoading(true);
    fetchProducts()
      .then((data) => {
        setProducts(
          data.map((p) => ({
            id: p.product_id,
            name: p.name,
            category: p.category,
            stock: Number(p.stock),
            reorderPoint: p.reorder_point ?? 0,
            supplier: p.supplier || "—",
          }))
        );
        setError("");
      })
      .catch((err) => setError(err.message || "Failed to load products"))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    loadProducts();
  }, []);

  if (loading) return <p className="p-6 text-gray-500">Loading products…</p>;
  if (error)
    return (
      <div className="p-6">
        <p className="text-red-600 mb-3">{error}</p>
        <button
          onClick={loadProducts}
          className="bg-blue-600 text-white px-4 py-2 rounded-lg text-sm"
        >
          Retry
        </button>
      </div>
    );

  const filtered = products.filter(
    (p) =>
      p.name.toLowerCase().includes(search.toLowerCase()) ||
      p.category.toLowerCase().includes(search.toLowerCase()) ||
      p.supplier.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div>
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-2xl font-bold">Products Catalogue</h2>
        <span className="text-sm text-gray-500">{products.length} products</span>
      </div>

      <input
        className="border border-gray-300 rounded-lg px-3 py-2 mb-4 w-72 bg-white"
        placeholder="Search by name, category, supplier..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      <div className="overflow-x-auto bg-white rounded-xl shadow">
        <table className="w-full text-left">
          <thead className="bg-gray-100 text-gray-700 font-semibold text-sm">
            <tr>
              <th className="p-3">Name</th>
              <th className="p-3">Category</th>
              <th className="p-3">Stock</th>
              <th className="p-3">Reorder Point</th>
              <th className="p-3">Supplier</th>
              <th className="p-3">Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 text-sm">
            {filtered.length === 0 ? (
              <tr>
                <td colSpan="6" className="p-6 text-center text-gray-400">
                  No products matched your search.
                </td>
              </tr>
            ) : (
              filtered.map((p) => (
                <tr key={p.id} className="hover:bg-gray-50">
                  <td className="p-3 font-medium text-gray-900">{p.name}</td>
                  <td className="p-3 text-gray-600">{p.category}</td>
                  <td className="p-3 text-gray-800">{p.stock}</td>
                  <td className="p-3 text-gray-800">{p.reorderPoint}</td>
                  <td className="p-3 text-gray-600">{p.supplier}</td>
                  <td className="p-3">
                    {p.stock <= p.reorderPoint ? (
                      <span className="bg-red-100 text-red-700 text-xs px-2.5 py-1 rounded-full font-semibold">
                        Reorder
                      </span>
                    ) : (
                      <span className="bg-green-100 text-green-700 text-xs px-2.5 py-1 rounded-full">
                        OK
                      </span>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
