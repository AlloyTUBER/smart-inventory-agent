import json
import math
import os
import re
from datetime import date
import ollama

# Allowed actions
ACTIONS = {"ORDER", "MARKDOWN", "HOLD"}

# Default settings
DEFAULT_LLM_MODEL = os.getenv("LLM_MODEL", "gemma4:e2b")
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")

SYSTEM_PROMPT = """You are the inventory manager of a small shop. For each product pick ONE action:
- ORDER    : create a purchase order now (give order_qty)
- MARKDOWN : stock will expire unsold, so discount it (no order)
- HOLD     : do nothing now
Guidelines: order when needs_order is true and there is no open PO. suggested_qty is
computed from the demand forecast; you may adjust it slightly (e.g. lower it for
perishables that would expire before selling) but not wildly. If order_by is still in the
future you may HOLD. Never ORDER if has_open_po or can_order is false.
Answer with JSON only, no prose, in this exact shape:
{"decisions":[{"product_id":1,"action":"ORDER","order_qty":120,"reason":"one short sentence"}]}"""


def _parse_json(raw: str):
    """Extract and parse decisions array from LLM markdown / JSON output."""
    raw = re.sub(r"^```(?:json)?|```$", "", raw.strip(), flags=re.M).strip()
    start, end = raw.find("{"), raw.rfind("}")
    if start == -1 or end == -1:
        raise ValueError(f"Could not locate JSON in response: {raw[:150]}")
    data = json.loads(raw[start : end + 1])
    return data.get("decisions", [])


def ollama_decide(flagged, model=DEFAULT_LLM_MODEL, system_prompt=SYSTEM_PROMPT):
    """
    Call Ollama LLM to generate structured inventory decisions.
    """
    client = ollama.Client(host=os.getenv("OLLAMA_HOST", OLLAMA_HOST))
    payload = "\n".join(json.dumps(i) for i in flagged.values())
    msg = client.chat(
        model=model,
        options={"num_predict": 3000},
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Today is {date.today()}. Products:\n{payload}"},
        ],
    )
    return _parse_json(msg.message.content)


def rule_decision(it):
    """Deterministic mathematical fallback decision when LLM is unavailable."""
    if it["can_order"] and not it["has_open_po"] and it["needs_order"] and it["suggested_qty"] > 0:
        return {
            "action": "ORDER",
            "order_qty": it["suggested_qty"],
            "reason": f"Stock {it['stock']} is at/below reorder point {it['reorder_point']}",
        }
    if it["at_risk_expiry_qty"] > 0:
        return {
            "action": "MARKDOWN",
            "order_qty": 0,
            "reason": f"~{it['at_risk_expiry_qty']} units expire by {it['expiry_date']} before selling",
        }
    return {
        "action": "HOLD",
        "order_qty": 0,
        "reason": "Stock sufficient for forecast demand",
    }


def validate(raw, items, actions=ACTIONS, min_factor=0.5, max_factor=1.5):
    """
    Validate LLM output against business rules, inventory constraints, and bounds.
    Prevents invalid quantities, hallucinated IDs, and impossible actions.
    """
    clean = {}
    for d in raw:
        try:
            pid = int(d["product_id"])
            action = str(d["action"]).upper()
        except (KeyError, TypeError, ValueError):
            continue

        it = items.get(pid)
        if it is None or action not in actions:
            continue

        reason = str(d.get("reason", ""))[:300]
        qty = 0

        if action == "ORDER":
            sug = it["suggested_qty"]
            if not it["can_order"] or it["has_open_po"] or sug <= 0:
                action, reason = (
                    "HOLD",
                    f"(order blocked: no supplier, open PO or nothing needed) {reason}",
                )
            else:
                try:
                    qty = int(d.get("order_qty", sug))
                except (TypeError, ValueError):
                    qty = sug
                qty = min(
                    max(qty, math.ceil(sug * min_factor)),
                    math.ceil(sug * max_factor),
                )
        elif action == "MARKDOWN" and it["at_risk_expiry_qty"] <= 0:
            action, reason = "HOLD", f"(no expiry risk) {reason}"

        clean[pid] = {"action": action, "order_qty": qty, "reason": reason}
    return clean


def decide(
    items,
    model=None,
    system_prompt=SYSTEM_PROMPT,
    actions=ACTIONS,
    min_factor=0.5,
    max_factor=1.5,
):
    """
    Main decision entrypoint.
    Runs Ollama on flagged products; falls back to deterministic rules if Ollama is unavailable.
    """
    flagged = {
        p: i
        for p, i in items.items()
        if i["needs_order"] or i["at_risk_expiry_qty"] > 0
    }
    if not flagged:
        return {}, "none needed"

    resolved_model = model or os.getenv("LLM_MODEL", DEFAULT_LLM_MODEL)
    used = f"ollama ({resolved_model})"

    try:
        raw_decisions = ollama_decide(
            flagged, model=resolved_model, system_prompt=system_prompt
        )
        decisions = validate(
            raw_decisions,
            items,
            actions=actions,
            min_factor=min_factor,
            max_factor=max_factor,
        )
    except Exception as e:
        decisions = {}
        used = f"rules (Ollama unavailable: {type(e).__name__}: {str(e)[:100]})"

    # Fill in any items skipped by LLM with deterministic rules
    for pid, it in flagged.items():
        decisions.setdefault(pid, rule_decision(it))

    return decisions, used
