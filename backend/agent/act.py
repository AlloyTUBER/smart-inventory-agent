import os
import sys
from datetime import timedelta
from sqlalchemy import text

# Ensure parent directory is in path to import database
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import engine

MODEL_NAME = os.getenv("MODEL_NAME", "pkl_model")
UPDATE_REORDER_POINTS = os.getenv("UPDATE_REORDER_POINTS", "true").lower() == "true"


def act(
    items,
    forecasts,
    decisions,
    today,
    db_engine=engine,
    model_name=MODEL_NAME,
    update_reorder_points=UPDATE_REORDER_POINTS,
):
    created_pos = []
    alerts = 0

    with db_engine.begin() as conn:
        # a) Store demand forecasts in demand_forecasts table
        fc_rows = [
            {
                "p": pid,
                "d": today + timedelta(days=i),
                "q": round(q, 2),
                "m": model_name,
            }
            for pid, f in forecasts.items()
            for i, q in enumerate(f)
        ]
        if fc_rows:
            conn.execute(
                text("""
                INSERT INTO demand_forecasts(product_id, forecast_date, predicted_qty, model_used)
                VALUES (:p, :d, :q, :m)
                ON CONFLICT (product_id, forecast_date, model_used)
                DO UPDATE SET predicted_qty = EXCLUDED.predicted_qty"""),
                fc_rows,
            )

        # b) Write AI-computed reorder points back to reorder_rules
        if update_reorder_points and items:
            conn.execute(
                text(
                    "UPDATE reorder_rules SET reorder_point = :rp WHERE product_id = :p"
                ),
                [
                    {"rp": i["reorder_point"], "p": pid}
                    for pid, i in items.items()
                ],
            )

        # c) Create draft purchase orders grouped by supplier
        by_supplier = {}
        for pid, d in decisions.items():
            if d["action"] != "ORDER":
                continue
            # Skip if an open PO already covers this product
            still_open = conn.execute(
                text("""
                SELECT 1 FROM po_items i
                JOIN purchase_orders po ON po.po_id = i.po_id
                WHERE i.product_id = :p AND po.status IN ('DRAFT','APPROVED','SENT')
                LIMIT 1"""),
                {"p": pid},
            ).first()
            if still_open:
                continue
            by_supplier.setdefault(items[pid]["supplier_id"], []).append(
                (pid, d)
            )

        for supplier_id, lines in by_supplier.items():
            reason = "AI agent: " + "; ".join(
                f"{items[p]['name']}: {d['reason']}" for p, d in lines
            )
            po_id = conn.execute(
                text("""
                INSERT INTO purchase_orders(supplier_id, status, created_by, reason)
                VALUES (:s, 'DRAFT', 'AGENT', :r)
                RETURNING po_id"""),
                {"s": supplier_id, "r": reason[:1000]},
            ).scalar()

            conn.execute(
                text("""
                INSERT INTO po_items(po_id, product_id, quantity, unit_cost)
                VALUES (:po, :p, :q, :c)"""),
                [
                    {
                        "po": po_id,
                        "p": p,
                        "q": d["order_qty"],
                        "c": items[p]["cost_price"],
                    }
                    for p, d in lines
                ],
            )
            created_pos.append(
                {
                    "po_id": po_id,
                    "supplier_id": supplier_id,
                    "items": len(lines),
                }
            )

        # d) Markdown suggestions become MARKDOWN alerts
        for pid, d in decisions.items():
            if d["action"] != "MARKDOWN":
                continue
            r = conn.execute(
                text("""
                INSERT INTO alerts(product_id, alert_type, message)
                SELECT :p, 'MARKDOWN', :m
                WHERE NOT EXISTS (
                    SELECT 1 FROM alerts
                    WHERE product_id = :p
                      AND alert_type = 'MARKDOWN'
                      AND is_resolved = FALSE
                )"""),
                {"p": pid, "m": f"Discount suggested: {d['reason']}"},
            )
            alerts += r.rowcount

    return created_pos, alerts
