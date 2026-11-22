import { useState, useEffect } from "react";
import { fetchPurchaseOrders, updatePOStatus, triggerAgent } from "../api";

const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:3000";

export default function PurchaseOrders() {
  const [orders, setOrders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [agentRunning, setAgentRunning] = useState(false);
  const [successMsg, setSuccessMsg] = useState("");
  const [poEmails, setPoEmails] = useState({});
  const [sendingPo, setSendingPo] = useState({});

  const handleMailApprovedPO = async (poId) => {
    const email = poEmails[poId]?.trim();
    if (!email || !email.includes("@")) {
      alert("Enter a valid supplier email.");
      return;
    }
    setSendingPo((prev) => ({ ...prev, [poId]: true }));
    try {
      const res = await fetch(`${API_BASE}/agent/send-po-invoice/${poId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ supplier_email: email }),
      });
      if (!res.ok) throw new Error((await res.json()).detail || "Failed to send");
      loadOrders(); // Refresh your PO list so status updates to SENT
    } catch (err) {
      alert(err.message);
    } finally {
      setSendingPo((prev) => ({ ...prev, [poId]: false }));
    }
  };

  const loadOrders = () => {
    setLoading(true);
    fetchPurchaseOrders()
      .then((data) => {
        setOrders(data);
        setError("");
      })
      .catch((err) =>
        setError(err.message || "Failed to load purchase orders")
      )
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    loadOrders();
  }, []);

  const handleStatusUpdate = async (poId, status) => {
    try {
      // user_id 1 as default approver
      await updatePOStatus(poId, status, 1);
      setSuccessMsg(`PO #${poId} updated to ${status}`);
      setTimeout(() => setSuccessMsg(""), 4000);
      loadOrders();
    } catch (err) {
      setError(err.response?.data?.detail || err.message);
    }
  };

  const handleRunAgent = async () => {
    setAgentRunning(true);
    setError("");
    setSuccessMsg("");
    try {
      const res = await triggerAgent();
      const posCount = res?.pos_created?.length || 0;
      setSuccessMsg(
        `AI Agent run complete! Evaluated ${res?.products_analysed || 0} products. Created ${posCount} new PO(s).`
      );
      loadOrders();
    } catch (err) {
      setError(
        err.response?.data?.detail ||
          err.message ||
          "Agent run failed"
      );
    } finally {
      setAgentRunning(false);
    }
  };

  if (loading)
    return <p className="p-6 text-gray-500">Loading purchase orders…</p>;

  const statusColor = {
    DRAFT: "bg-yellow-100 text-yellow-700",
    APPROVED: "bg-green-100 text-green-700",
    REJECTED: "bg-red-100 text-red-700",
    SENT: "bg-blue-100 text-blue-700",
    RECEIVED: "bg-gray-100 text-gray-700",
  };

  return (
    <div>
      <div className="flex justify-between items-center mb-4">
        <div>
          <h2 className="text-2xl font-bold">Purchase Orders</h2>
          <p className="text-sm text-gray-500">
            Autonomous AI suggestions and supplier order lifecycle
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={loadOrders}
            className="text-sm bg-gray-200 hover:bg-gray-300 px-3 py-2 rounded-lg text-gray-700"
          >
            🔄 Refresh
          </button>
          <button
            onClick={handleRunAgent}
            disabled={agentRunning}
            className="bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 text-white px-4 py-2 rounded-lg flex items-center gap-2 text-sm font-medium transition shadow-sm"
          >
            {agentRunning ? (
              <>
                <span className="animate-spin inline-block w-4 h-4 border-2 border-white border-t-transparent rounded-full" />
                Running AI Agent…
              </>
            ) : (
              "🤖 Run AI Agent"
            )}
          </button>
        </div>
      </div>

      {successMsg && (
        <div className="bg-green-50 border border-green-200 text-green-800 p-3 rounded-lg mb-4 text-sm flex justify-between items-center">
          <span>{successMsg}</span>
          <button
            onClick={() => setSuccessMsg("")}
            className="text-green-600 hover:text-green-900 font-bold"
          >
            ×
          </button>
        </div>
      )}

      {error && (
        <div className="text-red-600 bg-red-50 border border-red-200 p-3 rounded-lg mb-4 text-sm flex justify-between items-center">
          <span>{error}</span>
          <button
            onClick={() => setError("")}
            className="text-red-600 hover:text-red-900 font-bold"
          >
            ×
          </button>
        </div>
      )}

      {orders.length === 0 && (
        <div className="bg-white rounded-xl shadow p-8 text-center text-gray-500">
          <p className="text-lg font-medium mb-1">No purchase orders found</p>
          <p className="text-sm">Click "Run AI Agent" to trigger inventory evaluation and generate draft purchase orders.</p>
        </div>
      )}

      {orders.map((o) => (
        <div key={o.po_id} className="bg-white rounded-xl shadow p-5 mb-4 border border-gray-100">
          <div className="flex justify-between items-start">
            <div>
              <div className="flex items-center gap-3">
                <span className="font-bold text-lg text-gray-900">PO #{o.po_id}</span>
                <span
                  className={`px-3 py-0.5 rounded-full text-xs font-semibold ${statusColor[o.status] || "bg-gray-100 text-gray-700"}`}
                >
                  {o.status}
                </span>
              </div>
              <p className="text-sm font-medium text-gray-700 mt-1">
                Supplier: <span className="text-gray-900 font-semibold">{o.supplier_name}</span>
              </p>

              {o.items && o.items.length > 0 && (
                <div className="mt-3 bg-gray-50 rounded-lg p-3 text-sm text-gray-700">
                  <p className="font-semibold text-xs uppercase tracking-wide text-gray-500 mb-1">
                    Line Items
                  </p>
                  {o.items.map((item, i) => (
                    <div key={i} className="flex justify-between py-1 border-b border-gray-100 last:border-0">
                      <span>• {item.product_name}</span>
                      <span className="font-medium text-gray-900">
                        {item.quantity} units @ ₹{item.unit_cost}
                      </span>
                    </div>
                  ))}
                </div>
              )}

              {o.reason && (
                <p className="text-sm text-gray-600 mt-2 bg-indigo-50/60 p-2.5 rounded-lg border border-indigo-100">
                  <span className="font-semibold text-indigo-900">AI Reasoning:</span> {o.reason}
                </p>
              )}

              <p className="text-xs text-gray-400 mt-2">
                Created: {new Date(o.created_at).toLocaleString()} by {o.created_by}
                {o.approved_by && ` • Approved by user #${o.approved_by}`}
              </p>
            </div>
          </div>

          {o.status === "DRAFT" && (
            <div className="mt-4 pt-3 border-t border-gray-100 flex gap-3">
              <button
                onClick={() => handleStatusUpdate(o.po_id, "APPROVED")}
                className="bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition"
              >
                ✓ Approve
              </button>
              <button
                onClick={() => handleStatusUpdate(o.po_id, "REJECTED")}
                className="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition"
              >
                ✕ Reject
              </button>
            </div>
          )}

         {o.status === "APPROVED" && (
            <div className="mt-4 pt-3 border-t border-gray-100 flex flex-col sm:flex-row flex-wrap gap-2 items-stretch sm:items-center">
              <input
                type="email"
                value={poEmails[o.po_id] || ""}
                onChange={(e) =>
                  setPoEmails({ ...poEmails, [o.po_id]: e.target.value })
                }
                placeholder="Supplier email (e.g. orders@supplier.com)"
                className="flex-1 min-w-[220px] px-3 py-2 text-sm border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
              <button
                onClick={() => handleMailApprovedPO(o.po_id)}
                disabled={sendingPo[o.po_id]}
                className="px-4 py-2 bg-slate-900 hover:bg-slate-800 text-white text-sm font-medium rounded-lg disabled:opacity-50 transition"
              >
                {sendingPo[o.po_id] ? "Sending…" : "✉️ Mail & Mark Sent"}
              </button>
              <button
                onClick={() => handleStatusUpdate(o.po_id, "SENT")}
                className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition"
              >
                📤 Mark Sent Only
              </button>
            </div>
          )}

          {o.status === "SENT" && (
            <div className="mt-4 pt-3 border-t border-gray-100 flex gap-3">
              <button
                onClick={() => handleStatusUpdate(o.po_id, "RECEIVED")}
                className="bg-purple-600 hover:bg-purple-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition"
              >
                📥 Mark as Received (Stock Batch Check-in)
              </button>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
