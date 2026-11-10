from agent.predict import (
    analyse,
    demand_over,
    forecast_all,
    load_model,
    inspect_model,
    HORIZON,
    COVER_DAYS,
    PERISHABLE_COVER_DAYS,
    EXPIRY_WINDOW,
)
from agent.decide import (
    decide,
    rule_decision,
    validate,
    ollama_decide,
    ACTIONS,
    SYSTEM_PROMPT,
)
from agent.act import act


def run_agent_cycle(dry_run=True):
    import importlib.util
    import os

    agent_script_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent.py"
    )
    spec = importlib.util.spec_from_file_location("agent_main", agent_script_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.run_agent_cycle(dry_run=dry_run)


__all__ = [
    "analyse",
    "demand_over",
    "forecast_all",
    "load_model",
    "inspect_model",
    "decide",
    "rule_decision",
    "validate",
    "ollama_decide",
    "act",
    "run_agent_cycle",
    "HORIZON",
    "COVER_DAYS",
    "PERISHABLE_COVER_DAYS",
    "EXPIRY_WINDOW",
    "ACTIONS",
    "SYSTEM_PROMPT",
]
