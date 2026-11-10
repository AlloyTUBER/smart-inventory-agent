from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, DBAPIError
from database import engine

router = APIRouter(tags=["Transactions"])

class TxnType(str, Enum):
    SALE = "SALE"
    RECEIPT = "RECEIPT"
    WASTE = "WASTE"
    ADJUST = "ADJUST"

class SaleIn(BaseModel):
    product_id: int
    batch_id: int
    quantity: int = Field(gt=0)
    user_id: int

class TransactionIn(BaseModel):
    product_id: int
    batch_id: Optional[int] = None
    txn_type: TxnType
    quantity: int = Field(gt=0)
    user_id: int

@router.post("/sale")
def record_sale(s: SaleIn):
    try:
        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO transactions (product_id, batch_id, txn_type, quantity, user_id)
                VALUES (:product_id, :batch_id, 'SALE', :quantity, :user_id)
            """), {
                "product_id": s.product_id,
                "batch_id": s.batch_id,
                "quantity": s.quantity,
                "user_id": s.user_id,
            })
        return {"status": "recorded", "txn_type": "SALE"}
    except (IntegrityError, DBAPIError) as exc:
        err = str(exc.orig) if hasattr(exc, "orig") else str(exc)
        if "stock_batches_quantity_check" in err or "quantity" in err.lower():
            raise HTTPException(400, "Not enough stock in this batch")
        raise HTTPException(400, err)

@router.post("/transactions")
def add_transaction(t: TransactionIn):
    try:
        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO transactions (product_id, batch_id, txn_type, quantity, user_id)
                VALUES (:product_id, :batch_id, :txn_type, :quantity, :user_id)
            """), {
                "product_id": t.product_id,
                "batch_id": t.batch_id,
                "txn_type": t.txn_type.value,
                "quantity": t.quantity,
                "user_id": t.user_id,
            })
        return {"status": "recorded", "txn_type": t.txn_type.value}
    except (IntegrityError, DBAPIError) as exc:
        err = str(exc.orig) if hasattr(exc, "orig") else str(exc)
        if "stock_batches_quantity_check" in err or "quantity" in err.lower():
            raise HTTPException(400, "Not enough stock in this batch")
        raise HTTPException(400, err)

@router.get("/transactions")
def get_transactions(
    product_id: Optional[int] = Query(None),
    txn_type: Optional[TxnType] = Query(None),
    limit: int = Query(50, ge=1, le=500),
):
    q = "SELECT * FROM transactions WHERE TRUE"
    params: dict = {}
    if product_id is not None:
        q += " AND product_id = :pid"
        params["pid"] = product_id
    if txn_type is not None:
        q += " AND txn_type = :ttype"
        params["ttype"] = txn_type.value
    q += " ORDER BY txn_time DESC LIMIT :lim"
    params["lim"] = limit
    with engine.connect() as conn:
        rows = conn.execute(text(q), params).mappings().all()
    return [dict(r) for r in rows]