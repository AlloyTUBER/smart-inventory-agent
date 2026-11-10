import { useState, useEffect } from "react";
import { fetchAlerts, fetchAllAlerts, resolveAlert } from "../api";

export default function Alerts() {
  const [alerts, setAlerts] = useState([]);
  const [showAll, setShowAll] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadAlerts = () => {
    setLoading(true);
    const fetcher = showAll ? fetchAllAlerts : fetchAlerts;
    fetcher()
      .then((data) => {
        setAlerts(data);
        setError("");
      })
      .catch((err) => setError(err.message || "Failed to load alerts"))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    loadAlerts();
  }, [showAll]);

  const handleResolve = async (alertId) => {
    try {
      await resolveAlert(alertId);
      loadAlerts();
    } catch (err) {
      setError(err.message || "Failed to resolve alert");
    }
  };

  if (loading) return <p className="p-6 text-gray-500">Loading alerts…</p>;

  const alertColor = {
    LOW_STOCK: "border-red-500 bg-red-50/20",
    NEAR_EXPIRY: "border-yellow-500 bg-yellow-50/20",
    MARKDOWN: "border-purple-500 bg-purple-50/20",
  };

  const badgeColor = {
    LOW_STOCK: "bg-red-100 text-red-700",
    NEAR_EXPIRY: "bg-yellow-100 text-yellow-700",
    MARKDOWN: "bg-purple-100 text-purple-700",
  };

  return (
    <div>
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-2xl font-bold">Inventory Alerts</h2>
        <div className="flex gap-2 items-center">
          <label className="text-sm text-gray-600 flex items-center gap-1.5 cursor-pointer mr-2">
            <input
              type="checkbox"
              checked={showAll}
              onChange={(e) => setShowAll(e.target.checked)}
              className="rounded"
            />
            Show resolved alerts
          </label>
          <button
            onClick={loadAlerts}
            className="text-sm bg-gray-200 hover:bg-gray-300 px-3 py-1.5 rounded-lg text-gray-700"
          >
            🔄 Refresh
          </button>
        </div>
      </div>

      {error && (
        <div className="bg-red-50 text-red-600 p-3 rounded-lg mb-4 text-sm">
          {error}
        </div>
      )}

      {alerts.length === 0 && (
        <div className="bg-white rounded-xl shadow p-8 text-center text-gray-500">
          🎉 No open alerts right now! All inventory levels are healthy.
        </div>
      )}

      {alerts.map((a) => (
        <div
          key={a.alert_id}
          className={`bg-white border-l-4 ${alertColor[a.alert_type] || "border-gray-400"} rounded-lg shadow p-4 mb-3`}
        >
          <div className="flex justify-between items-center">
            <div className="flex items-center gap-2">
              <span
                className={`text-xs px-2.5 py-0.5 rounded-full font-medium ${badgeColor[a.alert_type] || "bg-gray-100 text-gray-700"}`}
              >
                {a.alert_type}
              </span>
              <p className="font-semibold text-gray-900">
                {a.product_name || `Product #${a.product_id}`}
              </p>
              {a.is_resolved && (
                <span className="text-xs text-gray-400 italic">(Resolved)</span>
              )}
            </div>
            <div className="flex items-center gap-3">
              <span className="text-xs text-gray-400">
                {new Date(a.created_at).toLocaleString()}
              </span>
              {!a.is_resolved && (
                <button
                  onClick={() => handleResolve(a.alert_id)}
                  className="text-xs text-blue-600 hover:underline hover:text-blue-800"
                >
                  Mark Resolved
                </button>
              )}
            </div>
          </div>
          <p className="text-sm text-gray-600 mt-2">{a.message}</p>
        </div>
      ))}
    </div>
  );
}
