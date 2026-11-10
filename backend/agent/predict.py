import math
import os
from datetime import timedelta
import joblib
import numpy as np
import pandas as pd

# Default settings
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSSIBLE_PATHS = [
    os.getenv("MODEL_PATH"),
    os.path.join(BASE_DIR, "model", "demand_forecast_model.pkl"),
    os.path.join(BASE_DIR, "demand_forecast_model.pkl"),
]
DEFAULT_MODEL_PATH = next(
    (p for p in POSSIBLE_PATHS if p and os.path.exists(p)),
    os.path.join(BASE_DIR, "model", "demand_forecast_model.pkl"),
)
MODEL_PATH = DEFAULT_MODEL_PATH

HORIZON = 14                 # Days the ML model forecasts ahead
COVER_DAYS = 14              # Safety cover window in days for standard products
PERISHABLE_COVER_DAYS = 5    # Shorter cover window for perishables
EXPIRY_WINDOW = 7            # Lookahead window in days for expiring batches

DEFAULT_FEATURES = [
    "product_id", "category_id", "unit_price", "is_perishable",
    "day_of_week", "is_weekend", "day_of_month", "month",
    "lag_1", "lag_2", "lag_7", "lag_14", "rolling_mean_7", "rolling_std_7",
]

_bundle = None


def load_model(model_path=None):
    """Load and cache the trained demand forecasting regression model."""
    global _bundle
    path = model_path or os.getenv("MODEL_PATH", DEFAULT_MODEL_PATH)
    if _bundle is None:
        obj = joblib.load(path)
        features = None
        if isinstance(obj, dict) and "model" in obj:
            features, obj = obj.get("features"), obj["model"]
        _bundle = (obj, features)
    return _bundle


def feature_row(pid, day, hist, meta=None):
    h = np.asarray(hist, dtype=float)
    fallback = float(h.mean()) if len(h) else 0.0

    def lag(n):
        return float(h[-n]) if len(h) >= n else fallback

    last7, last14 = h[-7:], h[-14:]
    p_meta = (meta or {}).get(pid, {})
    return {
        "product_id": pid,
        "category_id": p_meta.get("category_id", 1),
        "unit_price": float(p_meta.get("unit_price", 10.0)),
        "is_perishable": int(bool(p_meta.get("is_perishable", False))),
        "day_of_week": day.weekday(),
        "dow": day.weekday(),
        "is_weekend": int(day.weekday() >= 5),
        "day_of_month": day.day,
        "month": day.month,
        "lag_1": lag(1),
        "lag_2": lag(2),
        "lag_7": lag(7),
        "lag_14": lag(14),
        "rolling_mean_7": float(last7.mean()) if len(last7) else 0.0,
        "roll_mean_7": float(last7.mean()) if len(last7) else 0.0,
        "rolling_mean_14": float(last14.mean()) if len(last14) else 0.0,
        "roll_mean_14": float(last14.mean()) if len(last14) else 0.0,
        "rolling_std_7": float(last7.std()) if len(last7) > 1 else 0.0,
        "roll_std_7": float(last7.std()) if len(last7) > 1 else 0.0,
    }


def forecast_all(sales, today, product_meta=None, model_path=None, horizon=HORIZON):
    model, features = load_model(model_path)
    out = {}
    for pid, g in sales.groupby("product_id"):
        pid = int(pid)
        m = model.get(pid) if isinstance(model, dict) else model
        if m is None:
            continue
        cols = features or list(getattr(m, "feature_names_in_", DEFAULT_FEATURES))
        hist = g.sort_values("day")["units_sold"].astype(float).tolist()
        preds = []
        for i in range(horizon):
            row = pd.DataFrame([feature_row(pid, today + timedelta(days=i), hist, product_meta)])
            missing = [c for c in cols if c not in row.columns]
            if missing:
                raise ValueError(
                    f"Model expects features {missing} that feature_row() does not produce."
                )
            y = max(0.0, float(np.ravel(m.predict(row[cols]))[0]))
            preds.append(y)
            hist.append(y)
        out[pid] = preds
    return out


def inspect_model(model_path=None):
    model, features = load_model(model_path)
    print("type                 :", type(model))
    if isinstance(model, dict):
        print("per-product dict, keys:", list(model)[:10], "...")
        model = next(iter(model.values()))
    print("features (bundle)    :", features)
    print("feature_names_in_    :", getattr(model, "feature_names_in_", None))
    print("n_features_in_       :", getattr(model, "n_features_in_", None))
    print("DEFAULT_FEATURES     :", DEFAULT_FEATURES)


def demand_over(f, n):
    n = max(0, int(n))
    daily = float(np.mean(f)) if len(f) else 0.0
    return float(sum(f[:n])) + daily * max(0, n - len(f))


def analyse(
    stock,
    forecasts,
    expiring,
    open_po,
    today,
    cover_days=COVER_DAYS,
    perishable_cover_days=PERISHABLE_COVER_DAYS,
):
    
    exp = {int(r.product_id): r for r in expiring.itertuples()}
    items = {}
    for r in stock.itertuples():
        pid = int(r.product_id)
        f = forecasts.get(pid)
        if f is None:
            continue
        can_order = pd.notna(r.supplier_id) and pd.notna(r.lead_time_days)
        lead = int(r.lead_time_days) if can_order else 7
        have = int(r.total_qty)
        safety = int(r.safety_stock)
        daily = float(np.mean(f))

        reorder_point = math.ceil(demand_over(f, lead) + safety)
        cover = perishable_cover_days if r.is_perishable else cover_days
        target_level = demand_over(f, lead + cover) + safety
        suggested = max(0, math.ceil(target_level - have))

        if have <= reorder_point:
            days_to_order = 0
        elif daily > 0.01:
            days_to_order = int((have - reorder_point) / daily)
        else:
            days_to_order = None
        order_by = (today + timedelta(days=days_to_order)).isoformat() if days_to_order is not None else None

        at_risk, last_expiry = 0, None
        if pid in exp:
            e = exp[pid]
            last_expiry = e.last_expiry
            days = max((last_expiry - today).days, 0)
            at_risk = max(0, int(math.ceil(float(e.qty) - demand_over(f, days))))

        items[pid] = {
            "product_id": pid,
            "name": r.name,
            "category": r.category,
            "perishable": bool(r.is_perishable),
            "stock": have,
            "forecast_daily": round(daily, 1),
            "forecast_7d": round(demand_over(f, 7), 1),
            "lead_time_days": lead,
            "safety_stock": safety,
            "reorder_point": reorder_point,
            "needs_order": have <= reorder_point,
            "order_by": order_by,
            "suggested_qty": suggested,
            "at_risk_expiry_qty": at_risk,
            "expiry_date": last_expiry.isoformat() if last_expiry is not None else None,
            "has_open_po": pid in open_po,
            "can_order": bool(can_order),
            "supplier_id": int(r.supplier_id) if can_order else None,
            "cost_price": float(r.cost_price) if can_order else None,
        }
    return items
