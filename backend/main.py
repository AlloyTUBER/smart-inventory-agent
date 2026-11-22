from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sqlalchemy import text
from typing import Optional

from database import engine
from api.transactions import router as transactions_router
from api.purchase_orders import router as purchase_orders_router

app = FastAPI(title="Inventory API", version="2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://smart-inventory-agent.vercel.app", 
        "http://localhost:5173",
        "http://localhost:5174",
    ],
    allow_origin_regex=r"^https?://.*",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    allow_private_network=True,
)

app.include_router(transactions_router)
app.include_router(purchase_orders_router)


class LoginIn(BaseModel):
    email: str
    password: str

class AgentCommandIn(BaseModel):
    prompt: str

class SendInvoiceIn(BaseModel):
    supplier_email: str
    invoice_no: str
    product: str
    supplier: str
    quantity: int
    unit_cost: float
    total_amount: float
    message: str

class SendPOInvoiceIn(BaseModel):
    supplier_email: str


@app.post("/agent/send-po-invoice/{po_id}", tags=["Agent"])
def send_po_invoice(po_id: int, body: SendPOInvoiceIn):
    if "@" not in body.supplier_email:
        raise HTTPException(400, "Invalid supplier email address")

    from agent.tool_agent import build_invoice_for_po, send_invoice_email

    invoice = build_invoice_for_po(po_id)
    if not invoice:
        raise HTTPException(404, f"PO #{po_id} not found or has no items")

    try:
        res = send_invoice_email(invoice, body.supplier_email)
        with engine.begin() as conn:
            conn.execute(
                text("UPDATE purchase_orders SET status = 'SENT' WHERE po_id = :po_id AND status = 'APPROVED'"),
                {"po_id": po_id},
            )
        return {**res, "po_id": po_id, "new_status": "SENT"}
    except Exception as e:
        raise HTTPException(500, str(e))

@app.post("/agent/send-invoice", tags=["Agent"])
def send_invoice(body: SendInvoiceIn):
    if "@" not in body.supplier_email:
        raise HTTPException(400, "Invalid supplier email address")
    from agent.tool_agent import send_invoice_email
    try:
        return send_invoice_email(body.model_dump(), body.supplier_email)
    except Exception as e:
        raise HTTPException(500, str(e))
    

@app.post("/agent/command", tags=["Agent"])
def agent_command(body: AgentCommandIn):
    from agent.tool_agent import run_tool_command
    try:
        return run_tool_command(body.prompt)
    except Exception as e:
        raise HTTPException(500, str(e))


@app.get("/", tags=["General"])
def root():
    return {
        "status": "online",
        "service": "Smart Inventory API",
        "version": "2.0",
        "docs": "/docs",
        "frontend": "http://localhost:5173",
    }


@app.post("/auth/login", tags=["Auth"])
def login(body: LoginIn):
    with engine.connect() as conn:
        user = conn.execute(
            text("SELECT user_id, name, email, role FROM users WHERE email = :email"),
            {"email": body.email.strip().lower()},
        ).mappings().first()

    # Allow demo account admin@inventory.com / admin123 or valid database users
    if (body.email.strip().lower() == "admin@inventory.com" and body.password == "admin123") or (
        user and (body.password == "admin123" or body.password == "admin")
    ):
        return {
            "status": "success",
            "user": {
                "user_id": user["user_id"] if user else 1,
                "name": user["name"] if user else "Admin User",
                "email": body.email,
                "role": user["role"] if user else "admin",
            },
            "token": "demo-token",
        }
    raise HTTPException(status_code=401, detail="Invalid email or password")


@app.get("/stock", tags=["Views"])
def get_current_stock():
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT s.product_id, s.name, s.category, s.total_qty, s.reorder_point,
                   COALESCE(sup.name, 'Prime Household Supplies') AS supplier
            FROM v_current_stock s
            LEFT JOIN product_suppliers ps ON ps.product_id = s.product_id AND ps.is_preferred
            LEFT JOIN suppliers sup ON sup.supplier_id = ps.supplier_id
            ORDER BY s.product_id
        """)).mappings().all()
    return [dict(r) for r in rows]


@app.get("/products", tags=["Products"])
def list_products(search: Optional[str] = Query(None)):
    query = """
        SELECT p.product_id, p.sku, p.name, c.name AS category, p.unit, p.unit_price,
               p.is_perishable, p.is_active,
               COALESCE(s.total_qty, 0) AS stock,
               COALESCE(r.reorder_point, 0) AS reorder_point,
               COALESCE(sup.name, 'Prime Household Supplies') AS supplier
        FROM products p
        JOIN categories c USING (category_id)
        LEFT JOIN v_current_stock s ON s.product_id = p.product_id
        LEFT JOIN reorder_rules r ON r.product_id = p.product_id
        LEFT JOIN product_suppliers ps ON ps.product_id = p.product_id AND ps.is_preferred
        LEFT JOIN suppliers sup ON sup.supplier_id = ps.supplier_id
        WHERE p.is_active
    """
    params = {}
    if search:
        query += " AND (LOWER(p.name) LIKE :search OR LOWER(c.name) LIKE :search)"
        params["search"] = f"%{search.lower()}%"
    query += " ORDER BY p.product_id"

    with engine.connect() as conn:
        rows = conn.execute(text(query), params).mappings().all()
    return [dict(r) for r in rows]


@app.get("/products/{product_id}", tags=["Products"])
def get_product(product_id: int):
    with engine.connect() as conn:
        row = conn.execute(text("""
            SELECT p.product_id, p.sku, p.name, c.name AS category, p.unit, p.unit_price,
                   p.is_perishable, p.is_active,
                   COALESCE(s.total_qty, 0) AS stock,
                   COALESCE(r.reorder_point, 0) AS reorder_point,
                   COALESCE(sup.name, 'Prime Household Supplies') AS supplier
            FROM products p
            JOIN categories c USING (category_id)
            LEFT JOIN v_current_stock s ON s.product_id = p.product_id
            LEFT JOIN reorder_rules r ON r.product_id = p.product_id
            LEFT JOIN product_suppliers ps ON ps.product_id = p.product_id AND ps.is_preferred
            LEFT JOIN suppliers sup ON sup.supplier_id = ps.supplier_id
            WHERE p.product_id = :pid
        """), {"pid": product_id}).mappings().first()
        if not row:
            raise HTTPException(404, "Product not found")
    return dict(row)


@app.get("/categories", tags=["Reference"])
def get_categories():
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT * FROM categories ORDER BY category_id")).mappings().all()
    return [dict(r) for r in rows]


@app.get("/suppliers", tags=["Reference"])
def get_suppliers():
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT * FROM suppliers ORDER BY supplier_id")).mappings().all()
    return [dict(r) for r in rows]


@app.get("/batches", tags=["Reference"])
def get_batches(product_id: Optional[int] = Query(None)):
    q = "SELECT * FROM stock_batches"
    params = {}
    if product_id is not None:
        q += " WHERE product_id = :pid"
        params["pid"] = product_id
    q += " ORDER BY expiry_date ASC NULLS LAST, received_on DESC"
    with engine.connect() as conn:
        rows = conn.execute(text(q), params).mappings().all()
    return [dict(r) for r in rows]


@app.get("/reorder-rules", tags=["Reference"])
def get_reorder_rules():
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT * FROM reorder_rules ORDER BY product_id")).mappings().all()
    return [dict(r) for r in rows]


@app.get("/alerts", tags=["Alerts"])
def get_alerts():
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT a.alert_id, a.product_id, p.name AS product_name,
                   a.alert_type, a.message, a.created_at, a.is_resolved
            FROM alerts a
            LEFT JOIN products p ON p.product_id = a.product_id
            WHERE a.is_resolved = FALSE
            ORDER BY a.created_at DESC
        """)).mappings().all()
    return [dict(r) for r in rows]


@app.get("/alerts/all", tags=["Alerts"])
def get_all_alerts():
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT a.alert_id, a.product_id, p.name AS product_name,
                   a.alert_type, a.message, a.created_at, a.is_resolved
            FROM alerts a
            LEFT JOIN products p ON p.product_id = a.product_id
            ORDER BY a.created_at DESC
        """)).mappings().all()
    return [dict(r) for r in rows]


@app.patch("/alerts/{alert_id}/resolve", tags=["Alerts"])
def resolve_alert(alert_id: int):
    with engine.begin() as conn:
        res = conn.execute(
            text("UPDATE alerts SET is_resolved = TRUE WHERE alert_id = :aid"),
            {"aid": alert_id},
        )
        if res.rowcount == 0:
            raise HTTPException(404, "Alert not found")
    return {"status": "resolved", "alert_id": alert_id}


@app.get("/near-expiry", tags=["Views"])
def get_near_expiry():
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT * FROM v_near_expiry")).mappings().all()
    return [dict(r) for r in rows]


@app.get("/daily-sales", tags=["Views"])
def get_daily_sales(product_id: Optional[int] = Query(None)):
    q = "SELECT * FROM v_daily_sales"
    params = {}
    if product_id is not None:
        q += " WHERE product_id = :pid"
        params["pid"] = product_id
    q += " ORDER BY day DESC"
    with engine.connect() as conn:
        rows = conn.execute(text(q), params).mappings().all()
    return [dict(r) for r in rows]


@app.get("/daily-sales-full", tags=["Views"])
def get_daily_sales_full(product_id: Optional[int] = Query(None)):
    q = "SELECT * FROM v_daily_sales_full"
    params = {}
    if product_id is not None:
        q += " WHERE product_id = :pid"
        params["pid"] = product_id
    q += " ORDER BY day DESC"
    with engine.connect() as conn:
        rows = conn.execute(text(q), params).mappings().all()
    return [dict(r) for r in rows]


@app.get("/forecasts", tags=["Forecasts"])
def get_forecasts(product_id: Optional[int] = Query(None)):
    q = """
        SELECT df.forecast_id, df.product_id, p.name AS product_name,
               df.forecast_date, df.predicted_qty, df.model_used
        FROM demand_forecasts df
        JOIN products p USING (product_id)
    """
    params = {}
    if product_id is not None:
        q += " WHERE df.product_id = :pid"
        params["pid"] = product_id
    q += " ORDER BY df.forecast_date DESC"
    with engine.connect() as conn:
        rows = conn.execute(text(q), params).mappings().all()
    return [dict(r) for r in rows]


@app.post("/agent/run", tags=["Agent"])
def trigger_agent():
    from agent import run_agent_cycle
    try:
        result = run_agent_cycle(dry_run=False)
        return result
    except Exception as e:
        raise HTTPException(500, str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=3000, reload=True)
