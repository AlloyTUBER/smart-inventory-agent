import { useState } from "react";
import api from "../api";

export default function AgentBar() {
  const [prompt, setPrompt] = useState("");
  const [loading, setLoading] = useState(false);
  const [response, setResponse] = useState(null);
  const [emails, setEmails] = useState({});
  const [mailStatus, setMailStatus] = useState({});

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!prompt.trim()) return;
    setLoading(true);
    setMailStatus({});
    try {
      const { data } = await api.post("/agent/command", { prompt });
      setResponse(data);
    } catch {
      setResponse({ reply: "Agent error: Could not reach backend." });
    } finally {
      setLoading(false);
    }
  };

  const handleSendInvoice = async (draft, index) => {
    const supplierEmail = emails[index]?.trim();
    if (!supplierEmail || !supplierEmail.includes("@")) {
      setMailStatus((prev) => ({ ...prev, [index]: "Enter a valid email." }));
      return;
    }

    setMailStatus((prev) => ({ ...prev, [index]: "Sending..." }));
    try {
      await api.post("/agent/send-invoice", {
        ...draft,
        supplier_email: supplierEmail,
      });
      setMailStatus((prev) => ({
        ...prev,
        [index]: `Sent to ${supplierEmail} & store owner.`,
      }));
    } catch (err) {
      setMailStatus((prev) => ({
        ...prev,
        [index]: err.response?.data?.detail || "Failed to send email.",
      }));
    }
  };

  return (
    <div className="bg-white p-4 rounded-xl shadow-sm border border-slate-200 mb-6">
      <form onSubmit={handleSubmit} className="flex flex-col sm:flex-row gap-2">
        <input
          type="text"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder='Ask agent: "Draft an invoice for 30 units of Paneer 200g"'
          className="flex-1 px-4 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
        <button
          type="submit"
          disabled={loading}
          className="px-5 py-2 bg-blue-600 text-white font-semibold rounded-lg hover:bg-blue-700 disabled:opacity-50"
        >
          {loading ? "Thinking..." : "Ask Agent"}
        </button>
      </form>

      {response && (
        <div className="mt-4 space-y-4">
          {response.reply && <p className="text-slate-700 text-sm">{response.reply}</p>}

          {response.drafts?.map((draft, i) => (
            <div key={i} className="p-4 bg-slate-50 border rounded-lg space-y-3">
              <div className="flex flex-wrap justify-between items-center gap-2">
                <p className="font-semibold text-sm">
                  {draft.invoice_no} — {draft.product} (Qty: {draft.quantity})
                </p>
                <span className="text-sm font-bold text-slate-800">
                  Total: ₹{draft.total_amount?.toFixed(2)}
                </span>
              </div>

              <pre className="text-xs bg-white p-3 rounded border text-slate-700 whitespace-pre-wrap font-mono">
                {draft.message}
              </pre>

              <div className="flex flex-col sm:flex-row gap-2">
                <input
                  type="email"
                  value={emails[i] || ""}
                  onChange={(e) => setEmails({ ...emails, [i]: e.target.value })}
                  placeholder="Supplier email (e.g. orders@supplier.com)"
                  className="flex-1 px-3 py-1.5 text-sm border rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <button
                  type="button"
                  onClick={() => handleSendInvoice(draft, i)}
                  className="px-4 py-1.5 bg-slate-900 text-white text-xs font-semibold rounded-md hover:bg-slate-800"
                >
                  Mail Supplier & Owner
                </button>
                <a
                  href={draft.whatsapp_url}
                  target="_blank"
                  rel="noreferrer"
                  className="px-3 py-1.5 bg-green-600 text-white text-xs font-semibold rounded-md text-center"
                >
                  WhatsApp
                </a>
              </div>

              {mailStatus[i] && (
                <p className="text-xs font-medium text-blue-700">{mailStatus[i]}</p>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}