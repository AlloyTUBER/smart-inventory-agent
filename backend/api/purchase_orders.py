from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel
from typing import Optional
from enum import Enum
from sqlalchemy import text
from database import engine

router = APIRouter(tags=["Purchase Orders"])

class POStatus(str, Enum):
    DRAFT = "DRAFT"
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"
    SENT = "SENT"
    RECEIVED = "RECEIVED"

class POStatusUpdate(BaseModel):
    status: POStatus
    approved_by: Optional[int] = None 

VALID_PO_TRANSITIONS = {
    "DRAFT":    {"APPROVED", "REJECTED"},
    "APPROVED": {"SENT", "REJECTED"},
    "SENT":     {"RECEIVED"},
}

@router.get("/purchase-orders")
def list_purchase_orders(status: Optional[POStatus] = Query(None)):
    q = """
        SELECT po.po_id, po.supplier_id, s.name AS supplier_name,
               po.status, po.created_by, po.created_at,
               po.approved_by, po.reason
        FROM purchase_orders po
        JOIN suppliers s ON s.supplier_id = po.supplier_id
    """
    params: dict = {}
    if status is not None:
        q += " WHERE po.status = :st"
        params["st"] = status.value
    q += " ORDER BY po.created_at DESC"
    
    with engine.connect() as conn:
        po_rows = conn.execute(text(q), params).mappings().all()

    result = []
    with engine.connect() as conn:
        for po in po_rows:
            items = conn.execute(text("""
                SELECT pi.product_id, p.name AS product_name,
                       pi.quantity, pi.unit_cost
                FROM po_items pi
                JOIN products p ON p.product_id = pi.product_id
                WHERE pi.po_id = :po_id
            """), {"po_id": po["po_id"]}).mappings().all()
            result.append({**dict(po), "items": [dict(i) for i in items]})

    return result

@router.get("/purchase-orders/{po_id}")
def get_purchase_order(po_id: int):
    with engine.connect() as conn:
        po = conn.execute(text("""
            SELECT po.po_id, po.supplier_id, s.name AS supplier_name,
                   po.status, po.created_by, po.created_at,
                   po.approved_by, po.reason
            FROM purchase_orders po
            JOIN suppliers s ON s.supplier_id = po.supplier_id
            WHERE po.po_id = :po_id
        """), {"po_id": po_id}).mappings().first()

        if not po:
            raise HTTPException(404, "Purchase order not found")

        items = conn.execute(text("""
            SELECT pi.product_id, p.name AS product_name,
                   pi.quantity, pi.unit_cost
            FROM po_items pi
            JOIN products p ON p.product_id = pi.product_id
            WHERE pi.po_id = :po_id
        """), {"po_id": po_id}).mappings().all()

    return {**dict(po), "items": [dict(i) for i in items]}

@router.patch("/purchase-orders/{po_id}")
def update_po_status(po_id: int, body: POStatusUpdate):
    new_status = body.status.value
    approved_by = body.approved_by

    if new_status in ("APPROVED", "RECEIVED") and approved_by is None:
        raise HTTPException(400, f"approved_by (user_id) is required when setting status to {new_status}")

    with engine.begin() as conn:
        current = conn.execute(
            text("SELECT status FROM purchase_orders WHERE po_id = :po_id"),
            {"po_id": po_id},
        ).scalar()

        if current is None:
            raise HTTPException(404, "Purchase order not found")

        allowed = VALID_PO_TRANSITIONS.get(current, set())
        if new_status not in allowed:
            raise HTTPException(
                400,
                f"Cannot transition from {current} to {new_status}. "
                f"Allowed: {', '.join(sorted(allowed)) if allowed else 'none (terminal state)'}",
            )

        conn.execute(text("""
            UPDATE purchase_orders
            SET status = :status, approved_by = :approved_by
            WHERE po_id = :po_id
        """), {
            "status": new_status,
            "approved_by": approved_by,
            "po_id": po_id,
        })

    return get_purchase_order(po_id)