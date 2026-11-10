import axios from "axios";

const api = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || 'http://localhost:3000',
  timeout: 30000,
});

// ── Views & Stock ──────────────────────────────────────────────────────────
export const fetchStock = () => api.get("/stock").then((r) => r.data);

export const fetchDailySales = (productId) =>
  api
    .get("/daily-sales", { params: productId ? { product_id: productId } : {} })
    .then((r) => r.data);

export const fetchDailySalesFull = (productId) =>
  api
    .get("/daily-sales-full", {
      params: productId ? { product_id: productId } : {},
    })
    .then((r) => r.data);

export const fetchNearExpiry = () =>
  api.get("/near-expiry").then((r) => r.data);

// ── Alerts ──────────────────────────────────────────────────────────────────
export const fetchAlerts = () => api.get("/alerts").then((r) => r.data);
export const fetchAllAlerts = () => api.get("/alerts/all").then((r) => r.data);
export const resolveAlert = (alertId) =>
  api.patch(`/alerts/${alertId}/resolve`).then((r) => r.data);

// ── Reference Data ──────────────────────────────────────────────────────────
export const fetchProducts = (search) =>
  api.get("/products", { params: search ? { search } : {} }).then((r) => r.data);

export const fetchProduct = (id) =>
  api.get(`/products/${id}`).then((r) => r.data);

export const fetchCategories = () =>
  api.get("/categories").then((r) => r.data);

export const fetchSuppliers = () => api.get("/suppliers").then((r) => r.data);

export const fetchBatches = (productId) =>
  api
    .get("/batches", { params: productId ? { product_id: productId } : {} })
    .then((r) => r.data);

export const fetchReorderRules = () =>
  api.get("/reorder-rules").then((r) => r.data);

// ── Transactions ────────────────────────────────────────────────────────────
export const recordSale = (data) =>
  api.post("/sale", data).then((r) => r.data);

export const fetchTransactions = (params) =>
  api.get("/transactions", { params }).then((r) => r.data);

// ── Purchase Orders ─────────────────────────────────────────────────────────
export const fetchPurchaseOrders = (status) =>
  api
    .get("/purchase-orders", { params: status ? { status } : {} })
    .then((r) => r.data);

export const fetchPurchaseOrder = (poId) =>
  api.get(`/purchase-orders/${poId}`).then((r) => r.data);

export const updatePOStatus = (poId, status, approvedBy = 1) =>
  api
    .patch(`/purchase-orders/${poId}`, {
      status,
      approved_by: approvedBy ?? 1,
    })
    .then((r) => r.data);

// ── Forecasts ───────────────────────────────────────────────────────────────
export const fetchForecasts = (productId) =>
  api
    .get("/forecasts", { params: productId ? { product_id: productId } : {} })
    .then((r) => r.data);

// ── Agent ───────────────────────────────────────────────────────────────────
export const triggerAgent = () => api.post("/agent/run").then((r) => r.data);

// ── Auth ────────────────────────────────────────────────────────────────────
export const login = (email, password) =>
  api.post("/auth/login", { email, password }).then((r) => r.data);

export default api;
