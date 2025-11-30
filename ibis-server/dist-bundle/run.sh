#!/bin/bash
# Run ibis-server
# Usage: ./run.sh [port] [workers]
#   or:  PORT=8000 WORKERS=2 ./run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"

# Activate virtual environment if not already active
if [[ -z "${VIRTUAL_ENV}" ]]; then
    if [[ ! -d "${VENV_DIR}" ]]; then
        echo "ERROR: Virtual environment not found. Run ./install.sh first"
        exit 1
    fi
    source "${VENV_DIR}/bin/activate"
fi

export PYTHONPATH="${SCRIPT_DIR}"
export REMOTE_FUNCTION_LIST_PATH="${SCRIPT_DIR}/resources/function_list"
export REMOTE_WHITE_FUNCTION_LIST_PATH="${SCRIPT_DIR}/resources/white_function_list"

PORT="${PORT:-${1:-8000}}"
WORKERS="${WORKERS:-${2:-2}}"

echo "Starting ibis-server..."
echo "  Port: ${PORT}"
echo "  Workers: ${WORKERS}"
echo "  Log Level: info"
echo "  Press Ctrl+C to stop"
echo ""

# Print available IP addresses to help with connectivity debugging
echo "Listening on:"
hostname -I | tr ' ' '\n' | grep -v '^$' | sed "s/^/  http:\/\//g" | sed "s/$/:${PORT}/g"
echo ""

exec gunicorn app.main:app --bind 0.0.0.0:${PORT} \
    -k uvicorn.workers.UvicornWorker \
    --workers ${WORKERS} \
    --log-level info \
    --access-logfile - \
    --error-logfile - \
    --max-requests 1000 \
    --max-requests-jitter 100 \
    --timeout 300 \
    --graceful-timeout 60
