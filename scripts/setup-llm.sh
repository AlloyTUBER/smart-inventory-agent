#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${LLM_MODEL:-gemma4:e2b}"

echo "=== Smart Inventory Agent — LLM Setup ==="
echo ""

# 1. Start Ollama container
echo "[1/3] Starting Ollama Docker container..."
cd "$SCRIPT_DIR"
docker compose up -d ollama
echo "  ✓ Container started"

# 2. Wait for Ollama to be ready
echo "[2/3] Waiting for Ollama server to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "  ✓ Ollama server is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ Timed out waiting for Ollama. Check: docker logs smart-inventory-ollama"
        exit 1
    fi
    sleep 2
done

# 3. Pull the model (downloaded from HuggingFace via Ollama's registry)
echo "[3/3] Pulling model '$MODEL' (this may take a while on first run)..."
docker exec smart-inventory-ollama ollama pull "$MODEL"
echo "  ✓ Model '$MODEL' is ready"

echo ""
echo "=== Setup Complete ==="
echo "Ollama is running at http://localhost:11434"
echo "Model: $MODEL"
echo ""
echo "To verify:  docker exec smart-inventory-ollama ollama list"
echo "To test:    docker exec smart-inventory-ollama ollama run $MODEL 'Hello!'"
