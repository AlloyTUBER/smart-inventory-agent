#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Smart Inventory Agent — Full Startup ==="
echo ""

# Determine Python binary (prefer project virtualenv)
if [ -f "$SCRIPT_DIR/venv/bin/python" ]; then
    PYTHON_BIN="$SCRIPT_DIR/venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
else
    echo "  ✗ Error: Python 3 not found."
    exit 1
fi

# 1. Database
echo "[1/4] Checking PostgreSQL on port 3010..."
if pg_isready -p 3010 -q 2>/dev/null; then
    echo "  ✓ PostgreSQL is running on port 3010"
else
    echo "  ⚠ PostgreSQL is NOT responding on port 3010."
    echo "    Run:  sudo bash scripts/setup-db-port.sh"
    echo "    (or if your PostgreSQL is on port 5432, update backend/.env accordingly)"
fi

# 2. Ollama
echo "[2/4] Checking Ollama..."
if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "  ✓ Ollama is running"
else
    echo "  ⚠ Ollama is not running. Starting via Docker..."
    bash "$SCRIPT_DIR/scripts/setup-llm.sh"
fi

# 3. Frontend dependencies
echo "[3/4] Checking frontend dependencies..."
if [ ! -d "$SCRIPT_DIR/frontend/node_modules" ]; then
    echo "  → Installing frontend node_modules (first run)..."
    (cd "$SCRIPT_DIR/frontend" && npm install)
    echo "  ✓ Frontend dependencies installed"
else
    echo "  ✓ Frontend dependencies present"
fi

# 4. Start Services
echo "[4/4] Starting backend and frontend..."

# Cleanup trap on exit
cleanup() {
    echo ""
    echo "Stopping all services..."
    if [ -n "${BACKEND_PID:-}" ]; then
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
    if [ -n "${FRONTEND_PID:-}" ]; then
        kill "$FRONTEND_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup INT TERM EXIT

# Start Backend
cd "$SCRIPT_DIR/backend"
"$PYTHON_BIN" -m uvicorn main:app --host 0.0.0.0 --port 3000 --reload &
BACKEND_PID=$!
echo "  ✓ Backend started on port 3000 (PID $BACKEND_PID)"

# Start Frontend
cd "$SCRIPT_DIR/frontend"
npm run dev &
FRONTEND_PID=$!
echo "  ✓ Frontend started on port 5173 (PID $FRONTEND_PID)"

echo ""
echo "=============================================="
echo "  Web App (Frontend) : http://localhost:5173"
echo "  API Service        : http://localhost:3000"
echo "  API Docs (Swagger) : http://localhost:3000/docs"
echo "  Ollama (LLM)       : http://localhost:11434"
echo "  Model              : gemma4:e2b"
echo "  PostgreSQL         : localhost:3010"
echo "=============================================="
echo ""
echo "Press Ctrl+C to stop all services"

wait
