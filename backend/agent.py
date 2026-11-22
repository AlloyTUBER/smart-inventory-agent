import json
import os
import sys
from datetime import date
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import text
from agent.tool_agent import run_tool_command

# Ensure backend directory is in sys.path
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

load_dotenv()
from database import engine

# Import respective functions from the agent package
from agent.predict import (
    forecast_all,
    analyse,
    inspect_model,
    EXPIRY_WINDOW,
    HORIZON,
)
from agent.decide import decide
from agent.act import act


LLM_MODEL = os.getenv("LLM_MODEL", "gemma4:e2b")


def observe():
    with engine.connect() as c:
        # Full zero-filled daily sales history for time-series forecasting
        sales = pd.read_sql(
            text("""
            SELECT product_id, day, units_sold FROM v_daily_sales_full
            WHERE day < CURRENT_DATE
            ORDER BY product_id, day
            """),
            c,
        )

        stock = pd.read_sql(
            text("""
            SELECT s.product_id, s.name, s.category, p.category_id, p.unit_price,
                   s.total_qty, p.is_perishable,
                   COALESCE(r.safety_stock, 0) AS safety_stock,
                   ps.supplier_id, ps.cost_price, ps.lead_time_days
            FROM v_current_stock s
            JOIN products p ON p.product_id = s.product_id
            LEFT JOIN reorder_rules r ON r.product_id = s.product_id
            LEFT JOIN product_suppliers ps ON ps.product_id = s.product_id AND ps.is_preferred
            WHERE p.is_active
            """),
            c,
        ).drop_duplicates("product_id")

        # Batches expiring soon that still have inventory
        expiring = pd.read_sql(
            text("""
            SELECT product_id, SUM(quantity) AS qty, MAX(expiry_date) AS last_expiry
            FROM stock_batches
            WHERE expiry_date IS NOT NULL AND quantity > 0
              AND expiry_date <= CURRENT_DATE + :w
            GROUP BY product_id
            """),
            c,
            params={"w": EXPIRY_WINDOW},
        )

        # Products currently on open purchase orders
        open_po = set(
            pd.read_sql(
                text("""
            SELECT DISTINCT i.product_id FROM po_items i
            JOIN purchase_orders po ON po.po_id = i.po_id
            WHERE po.status IN ('DRAFT','APPROVED','SENT')
            """),
                c,
            )["product_id"].astype(int)
        )

    return sales, stock, expiring, open_po


def run_agent_cycle(dry_run=True):
    """
    Execute one complete autonomous inventory management cycle.
    """
    today = date.today()

    sales, stock, expiring, open_po = observe()

    product_meta = (
        stock.set_index("product_id").to_dict(orient="index")
        if "product_id" in stock.columns
        else {}
    )
    forecasts = forecast_all(sales, today, product_meta=product_meta)
    items = analyse(stock, forecasts, expiring, open_po, today)

    decisions, decided_by = decide(items, model=LLM_MODEL)

    plan = [
        {
            **{
                k: items[p][k]
                for k in (
                    "product_id",
                    "name",
                    "stock",
                    "forecast_daily",
                    "reorder_point",
                    "order_by",
                    "lead_time_days",
                )
            },
            **d,
        }
        for p, d in decisions.items()
    ]

    result = {
        "dry_run": dry_run,
        "decided_by": decided_by,
        "products_analysed": len(items),
        "plan": plan,
        "pos_created": [],
        "alerts_created": 0,
    }
    if not dry_run:
        result["pos_created"], result["alerts_created"] = act(
            items, forecasts, decisions, today, db_engine=engine
        )

    return result


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    if mode == "--inspect":
        inspect_model()
    elif mode == "--command" and len(sys.argv) > 2:
        prompt = " ".join(sys.argv[2:])
        print(json.dumps(run_tool_command(prompt, model=LLM_MODEL), indent=2, default=str))
    else:
        is_dry_run = mode != "--run"
        cycle_result = run_agent_cycle(dry_run=is_dry_run)
        print(json.dumps(cycle_result, indent=2, default=str))
