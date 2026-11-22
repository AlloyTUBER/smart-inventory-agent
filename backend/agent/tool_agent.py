import os
import urllib.parse
import httpx
from sqlalchemy import text
from database import engine
from difflib import get_close_matches
import smtplib
from datetime import date
from email.message import EmailMessage
import uuid


OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434/api/chat")
LLM_MODEL = os.getenv("LLM_MODEL", "gemma4:e2b")

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_low_stock_items",
            "description": "Fetch products where current stock is at or below the reorder point, optionally filtered by category.",
            "parameters": {
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "description": "Optional category name (e.g., Dairy, Snacks)",
                    }
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_near_expiry_items",
            "description": "Fetch inventory batches that are expiring soon.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_approved_purchase_orders",
            "description": "Fetch all APPROVED purchase orders and generate ready-to-mail supplier invoice drafts for them.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    # 1. Update the tool description in TOOLS
    {
        "type": "function",
        "function": {
            "name": "draft_purchase_order",
            "description": "Draft a supplier invoice, purchase order (PO), or restock order with WhatsApp and Email details for a specific product.",
            "parameters": {
                "type": "object",
                "properties": {
                    "product_name": {"type": "string"},
                    "quantity": {"type": "integer"},
                },
                "required": ["product_name", "quantity"],
            },
        },
    },
]


def _get_low_stock_items(category: str | None = None):
    query = """
        SELECT s.product_id, s.name, s.category, s.total_qty AS stock, s.reorder_point,
               COALESCE(sup.name, 'Prime Household Supplies') AS supplier
        FROM v_current_stock s
        LEFT JOIN product_suppliers ps ON ps.product_id = s.product_id AND ps.is_preferred
        LEFT JOIN suppliers sup ON sup.supplier_id = ps.supplier_id
        WHERE s.total_qty <= s.reorder_point
    """
    params = {}
    if category:
        query += " AND LOWER(s.category) LIKE :cat"
        params["cat"] = f"%{category.lower()}%"
    query += " ORDER BY s.total_qty ASC"

    with engine.connect() as conn:
        rows = conn.execute(text(query), params).mappings().all()
    return [dict(r) for r in rows]


def _get_near_expiry_items():
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT * FROM v_near_expiry")).mappings().all()
    return [dict(r) for r in rows]

def build_invoice_for_po(po_id: int) -> dict | None:
    with engine.connect() as conn:
        po = conn.execute(
            text("""
                SELECT po.po_id, po.status, COALESCE(sup.name, 'Supplier') AS supplier
                FROM purchase_orders po
                LEFT JOIN suppliers sup ON sup.supplier_id = po.supplier_id
                WHERE po.po_id = :po_id
            """),
            {"po_id": po_id},
        ).mappings().first()
        if not po:
            return None

        items = conn.execute(
            text("""
                SELECT p.name, p.sku, i.quantity,
                       COALESCE(i.unit_cost, p.unit_price, 0) AS unit_cost
                FROM po_items i
                JOIN products p ON p.product_id = i.product_id
                WHERE i.po_id = :po_id
            """),
            {"po_id": po_id},
        ).mappings().all()

    if not items:
        return None

    invoice_no = f"PO-{po_id}-{date.today().strftime('%Y%m%d')}"
    lines = []
    total_amount = 0.0
    total_qty = 0

    for item in items:
        qty = int(item["quantity"])
        cost = float(item["unit_cost"])
        line_total = round(qty * cost, 2)
        total_amount += line_total
        total_qty += qty
        lines.append(f"- {item['name']} (SKU: {item['sku']}) x {qty} @ ₹{cost:.2f} = ₹{line_total:.2f}")

    total_amount = round(total_amount, 2)
    product_summary = items[0]["name"] if len(items) == 1 else f"{items[0]['name']} (+{len(items) - 1} more)"

    invoice_text = (
        f"APPROVED PURCHASE ORDER / SUPPLIER INVOICE\n"
        f"----------------------------------------\n"
        f"Invoice No : {invoice_no}\n"
        f"PO ID      : #{po_id}\n"
        f"Date       : {date.today().isoformat()}\n"
        f"Supplier   : {po['supplier']}\n"
        f"Items      :\n" + "\n".join(lines) + "\n"
        f"----------------------------------------\n"
        f"Total      : ₹{total_amount:.2f}\n"
        f"Please confirm availability and expected delivery date."
    )

    return {
        "po_id": po_id,
        "invoice_no": invoice_no,
        "date": date.today().isoformat(),
        "product": product_summary,
        "supplier": po["supplier"],
        "quantity": total_qty,
        "unit_cost": round(total_amount / total_qty, 2) if total_qty else 0.0,
        "total_amount": total_amount,
        "message": invoice_text,
        "whatsapp_url": f"https://wa.me/?text={urllib.parse.quote(invoice_text)}",
    }


def _get_approved_po_drafts() -> list[dict]:
    with engine.connect() as conn:
        rows = conn.execute(
            text("SELECT po_id FROM purchase_orders WHERE status = 'APPROVED' ORDER BY po_id DESC")
        ).mappings().all()

    drafts = []
    for r in rows:
        inv = build_invoice_for_po(r["po_id"])
        if inv:
            drafts.append(inv)
    return drafts

def _find_product_row(conn, product_name: str):
    base_query = """
        SELECT p.name, p.sku,
               COALESCE(ps.cost_price, p.unit_price, 0) AS unit_cost,
               COALESCE(sup.name, 'Prime Household Supplies') AS supplier
        FROM products p
        LEFT JOIN product_suppliers ps ON ps.product_id = p.product_id AND ps.is_preferred
        LEFT JOIN suppliers sup ON sup.supplier_id = ps.supplier_id
        WHERE p.is_active
    """
    # 1. Substring match first
    row = conn.execute(
        text(base_query + " AND LOWER(p.name) LIKE :name LIMIT 1"),
        {"name": f"%{product_name.lower().strip()}%"},
    ).mappings().first()
    if row:
        return row

    # 2. Fuzzy match fallback for typos (e.g. "panner" -> "Paneer 200g")
    all_rows = conn.execute(text(base_query)).mappings().all()
    if not all_rows:
        return None

    query = product_name.lower().strip()
    by_name = {r["name"].lower(): r for r in all_rows}
    matches = get_close_matches(query, by_name.keys(), n=1, cutoff=0.55)
    if matches:
        return by_name[matches[0]]

    # 3. Word-level fuzzy match (matches "panner" against "paneer" in "Paneer 200g")
    by_word = {}
    for r in all_rows:
        for word in r["name"].lower().split():
            by_word.setdefault(word, r)
    word_matches = get_close_matches(query, by_word.keys(), n=1, cutoff=0.65)
    return by_word[word_matches[0]] if word_matches else None

def _draft_purchase_order(product_name: str, quantity: int):
    with engine.connect() as conn:
        row = _find_product_row(conn, product_name)

    resolved_name = row["name"] if row else product_name
    sku = row["sku"] if row else "N/A"
    supplier = row["supplier"] if row else "Supplier"
    unit_cost = float(row["unit_cost"]) if row else 0.0
    total_amount = round(unit_cost * quantity, 2)
    invoice_no = f"INV-{date.today().strftime('%Y%m%d')}-{uuid.uuid4().hex[:4].upper()}"

    invoice_text = (
        f"APPROVED PURCHASE ORDER / SUPPLIER INVOICE\n"
        f"----------------------------------------\n"
        f"Invoice No : {invoice_no}\n"
        f"PO ID      : Draft\n"
        f"Date       : {date.today().isoformat()}\n"
        f"Supplier   : {supplier}\n"
        f"Items      :\n"
        f"- {resolved_name} (SKU: {sku}) x {quantity} @ ₹{unit_cost:.2f} = ₹{total_amount:.2f}\n"
        f"----------------------------------------\n"
        f"Total      : ₹{total_amount:.2f}\n"
        f"Please confirm availability and expected delivery date."
    )
    encoded = urllib.parse.quote(invoice_text)

    return {
        "invoice_no": invoice_no,
        "date": date.today().isoformat(),
        "product": resolved_name,
        "sku": sku,
        "supplier": supplier,
        "quantity": quantity,
        "unit_cost": unit_cost,
        "total_amount": total_amount,
        "message": invoice_text,
        "whatsapp_url": f"https://wa.me/?text={encoded}",
    }


def send_invoice_email(invoice: dict, supplier_email: str):
    smtp_host = os.getenv("SMTP_HOST", "smtp.gmail.com")
    smtp_port = int(os.getenv("SMTP_PORT", "587"))
    smtp_user = os.getenv("SMTP_USER")
    smtp_pass = os.getenv("SMTP_PASS")
    owner_email = os.getenv("STORE_OWNER_EMAIL")

    if not smtp_user or not smtp_pass:
        raise RuntimeError("SMTP_USER and SMTP_PASS must be set in .env")

    recipients = [supplier_email.strip()]
    if owner_email:
        recipients.append(owner_email.strip())

    msg = EmailMessage()
    msg["Subject"] = f"Invoice Draft {invoice['invoice_no']} - {invoice['product']}"
    msg["From"] = smtp_user
    msg["To"] = supplier_email.strip()
    if owner_email:
        msg["Cc"] = owner_email.strip()
    msg.set_content(invoice["message"])

    with smtplib.SMTP(smtp_host, smtp_port, timeout=20) as server:
        server.starttls()
        server.login(smtp_user, smtp_pass)
        server.send_message(msg, to_addrs=recipients)

    return {"status": "sent", "sent_to": recipients, "invoice_no": invoice["invoice_no"]}

def run_tool_command(prompt: str, model: str = LLM_MODEL) -> dict:
    messages = [
       {
            "role": "system",
            "content": (
                "You are an autonomous inventory assistant. "
                "Whenever the user asks to draft an invoice, supplier invoice, purchase order, PO, or restock order, "
                "you MUST call the `draft_purchase_order` tool. Do not refuse or write it in plain text."
            ),
        },
        {"role": "user", "content": prompt},
    ]

    res = httpx.post(
        OLLAMA_URL,
        json={"model": model, "messages": messages, "tools": TOOLS, "stream": False},
        timeout=60.0,
    )
    res.raise_for_status()
    reply = res.json()["message"]

    tool_calls = reply.get("tool_calls", [])
    results = []
    drafts = []

    for call in tool_calls:
        fn_name = call["function"]["name"]
        args = call["function"].get("arguments", {})

        if fn_name == "get_low_stock_items":
            items = _get_low_stock_items(args.get("category"))
            results.append({"tool": fn_name, "count": len(items), "items": items})
        elif fn_name == "get_approved_purchase_orders":
            drafts.extend(_get_approved_po_drafts())

        elif fn_name == "get_near_expiry_items":
            items = _get_near_expiry_items()
            results.append({"tool": fn_name, "count": len(items), "items": items})

        elif fn_name == "draft_purchase_order":
            draft = _draft_purchase_order(
                product_name=args["product_name"],
                quantity=int(args["quantity"]),
            )
            drafts.append(draft)

    return {
        "reply": reply.get("content") or "Done.",
        "results": results,
        "drafts": drafts,
    }