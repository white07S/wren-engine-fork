#!/bin/bash
# Install script for TARGET machines
# Requirements: Python 3.11 + pip ONLY
# NO Rust, NO poetry, NO build tools, NO compilation needed!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"

echo "=== Installing ibis-server ==="
echo ""

# Check Python version
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
if ! command -v "${PYTHON_BIN}" &> /dev/null; then
    PYTHON_BIN="python3"
fi

PYTHON_VERSION=$("${PYTHON_BIN}" --version 2>&1 | cut -d' ' -f2 | cut -d'.' -f1,2)
if [[ "${PYTHON_VERSION}" != "3.11" ]]; then
    echo "ERROR: Python 3.11 required, found ${PYTHON_VERSION}"
    echo "Set PYTHON_BIN environment variable to point to Python 3.11"
    exit 1
fi
echo "✓ Python ${PYTHON_VERSION} found"

# Create virtual environment
echo ">>> Creating virtual environment..."
rm -rf "${VENV_DIR}"
"${PYTHON_BIN}" -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"

# Upgrade pip
echo ">>> Upgrading pip..."
pip install --upgrade pip wheel setuptools --quiet

# Install all wheels OFFLINE (no internet, no compilation)
echo ">>> Installing pre-built wheels (offline)..."
echo "    This may take a minute..."

# Install wheels one by one to avoid conflicts
# Start with core dependencies, then ibis, then the rest
WHEEL_DIR="${SCRIPT_DIR}/wheels"

# Install in order: no-deps first for all, then let pip resolve
for wheel in "${WHEEL_DIR}"/*.whl; do
    pip install --no-index --find-links="${WHEEL_DIR}" "${wheel}" --no-deps --quiet 2>/dev/null || true
done

# Now run pip check and fix any issues
echo "    Resolving dependencies..."
pip install --no-index --find-links="${WHEEL_DIR}" \
    ibis-framework wren-core-py wren-engine fastapi uvicorn gunicorn pydantic \
    --quiet 2>/dev/null || true

# Verify critical packages
echo ""
echo ">>> Verifying installation..."
FAILED=0

for pkg in fastapi uvicorn gunicorn pydantic asgi_correlation_id; do
    if python -c "import ${pkg}" 2>/dev/null; then
        echo "    ✓ ${pkg}"
    else
        echo "    ✗ ${pkg} - FAILED"
        FAILED=1
    fi
done

# Check ibis separately (module name is 'ibis')
if python -c "import ibis" 2>/dev/null; then
    echo "    ✓ ibis"
else
    echo "    ✗ ibis - FAILED"
    FAILED=1
fi

# Check wren_core
if python -c "import wren_core" 2>/dev/null; then
    echo "    ✓ wren_core"
else
    echo "    ✗ wren_core - FAILED"
    FAILED=1
fi

if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "WARNING: Some packages failed to verify."
    echo "The server may still work. Try running: ./run.sh"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "To run the server:"
echo "  cd ${SCRIPT_DIR}"
echo "  ./run.sh"
echo ""
