#!/bin/bash
# Build a distributable package for ibis-server
# Run this on your BUILD machine (with Rust, poetry, etc.)
# The output can be deployed to any Linux machine with just Python 3.11
#
# BUILD MACHINE REQUIREMENTS:
#   - Python 3.11
#   - Rust (for compiling wren-core-py)
#   - Poetry
#   - System libs: libpq-dev, default-libmysqlclient-dev, unixodbc-dev
#
# TARGET MACHINE REQUIREMENTS (much simpler):
#   - Python 3.11
#   - System libs: libpq5, libmysqlclient21, libodbc1 (runtime only, not -dev)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist-bundle"
WHEELS_DIR="${DIST_DIR}/wheels"

echo "=== Building Distributable ibis-server Package ==="
echo "Build machine: $(uname -m)"

# Ensure Python 3.11 is used
if command -v python3.11 &> /dev/null; then
    export PYTHON_BIN="python3.11"
else
    echo "ERROR: Python 3.11 not found. Please install python3.11"
    exit 1
fi
echo "Using Python: $($PYTHON_BIN --version)"

# Clean previous builds
rm -rf "${DIST_DIR}"
mkdir -p "${WHEELS_DIR}"

# Step 1: Build wren-core-py wheel (Rust extension)
echo ""
echo ">>> [1/5] Building wren-core-py wheel (Rust extension)..."
cd "${SCRIPT_DIR}/../wren-core-py"
poetry env use "${PYTHON_BIN}" 2>/dev/null || true
poetry install --no-root
ENV=prod poetry run maturin build --release
cp target/wheels/*.whl "${WHEELS_DIR}/"
echo "    ✓ wren-core-py wheel built"

# Step 2: Install ibis-server dependencies and build wheel
echo ""
echo ">>> [2/5] Building ibis-server and collecting dependencies..."
cd "${SCRIPT_DIR}"

# Ensure poetry uses Python 3.11
poetry env use "${PYTHON_BIN}" 2>/dev/null || true

# Install dependencies first (this compiles everything)
poetry install --without dev --without jupyter

# Patch pyproject.toml to replace git dependency with version dependency
# This ensures the built wheel depends on the version, not the git URL
echo "    Patching pyproject.toml for distribution..."
cp pyproject.toml pyproject.toml.bak
IBIS_VERSION=$(poetry run pip show ibis-framework | grep "^Version:" | cut -d' ' -f2)
echo "      Detected ibis-framework version: ${IBIS_VERSION}"

# Install tomlkit for patching
poetry run pip install tomlkit --quiet

# Use python to patch toml
poetry run python -c "
import tomlkit
import os

ver = '${IBIS_VERSION}'
try:
    with open('pyproject.toml', 'r') as f:
        doc = tomlkit.parse(f.read())

    deps = doc['tool']['poetry']['dependencies']
    if 'ibis-framework' in deps:
        ibis = deps['ibis-framework']
        # Check if it's a git dependency (might be a dict or inline table)
        if isinstance(ibis, dict) and 'git' in ibis:
            # Keep extras
            extras = ibis.get('extras', [])
            # Create new dependency dict
            new_ibis = {'version': ver, 'extras': extras}
            deps['ibis-framework'] = new_ibis
            
            with open('pyproject.toml', 'w') as f:
                f.write(tomlkit.dumps(doc))
            print('      Successfully patched pyproject.toml')
        else:
            print('      ibis-framework does not have git dependency, skipping patch')
except Exception as e:
    print(f'      Error patching pyproject.toml: {e}')
    # Don't fail the build, maybe it's already correct
"

# Build ibis-server wheel
poetry build --format wheel

# Restore pyproject.toml
mv pyproject.toml.bak pyproject.toml
echo "    Restored pyproject.toml"
cp dist/*.whl "${WHEELS_DIR}/"
echo "    ✓ ibis-server wheel built"

# Step 3: Collect all pre-built wheels from the venv
echo ""
echo ">>> [3/5] Collecting all dependency wheels..."

# Get the virtual environment path
VENV_PATH=$(poetry env info -p 2>/dev/null || poetry run python -c "import sys; print(sys.prefix)")
echo "    Virtual env: ${VENV_PATH}"

# Generate exact requirements with versions (excluding git/file installs)
echo "    Generating exact package versions..."
poetry run pip freeze | grep -v "@ git+" | grep -v "@ file:" | grep "==" > "${DIST_DIR}/requirements-exact.txt"
PKG_COUNT=$(wc -l < "${DIST_DIR}/requirements-exact.txt")
echo "    Found ${PKG_COUNT} packages to download"

# Download all wheels from PyPI with exact versions
echo "    Downloading wheels from PyPI..."
poetry run pip download \
    -r "${DIST_DIR}/requirements-exact.txt" \
    -d "${WHEELS_DIR}" \
    --only-binary=:all: \
    --no-deps \
    2>&1 | tee /tmp/pip-download.log | grep -c "Saved" | xargs -I{} echo "      Downloaded {} packages" || true

# Check how many we got
DOWNLOADED=$(ls "${WHEELS_DIR}"/*.whl 2>/dev/null | wc -l)
echo "    Got ${DOWNLOADED} wheels so far"

# If download failed for some, try without --only-binary for those
if [[ ${DOWNLOADED} -lt ${PKG_COUNT} ]]; then
    echo "    Some packages need building, attempting..."
    # Get packages that failed
    for pkg in $(cat "${DIST_DIR}/requirements-exact.txt"); do
        pkg_name=$(echo "$pkg" | cut -d'=' -f1)
        if ! ls "${WHEELS_DIR}"/${pkg_name}*.whl &>/dev/null 2>&1; then
            if ! ls "${WHEELS_DIR}"/${pkg_name//-/_}*.whl &>/dev/null 2>&1; then
                echo "      Building ${pkg_name}..."
                poetry run pip wheel "${pkg}" --wheel-dir="${WHEELS_DIR}" --no-deps --quiet 2>/dev/null || true
            fi
        fi
    done
fi

# Build wheel for ibis-framework from the installed git version
echo "    Building ibis-framework wheel from git..."
IBIS_VERSION=$(poetry run pip show ibis-framework | grep "^Version:" | cut -d' ' -f2)
echo "      ibis-framework version: ${IBIS_VERSION}"

# Get the exact git requirement from pip freeze to ensure we build the correct commit
IBIS_REQ=$(poetry run pip freeze | grep "ibis-framework @")
if [[ -z "${IBIS_REQ}" ]]; then
    echo "      WARNING: ibis-framework not found in pip freeze as git dependency. Using 'ibis-framework'..."
    IBIS_REQ="ibis-framework==${IBIS_VERSION}"
else
    echo "      Found git requirement: ${IBIS_REQ}"
fi

# Remove any existing ibis wheels first (may have wrong version from PyPI)
rm -f "${WHEELS_DIR}"/ibis_framework*.whl 2>/dev/null || true

# Build the wheel from the git requirement
poetry run pip wheel "${IBIS_REQ}" --wheel-dir="${WHEELS_DIR}" --no-deps --quiet 2>/dev/null || true

# Verify ibis wheel was created with correct version
if ls "${WHEELS_DIR}"/ibis_framework-${IBIS_VERSION}*.whl &>/dev/null; then
    echo "      ✓ ibis-framework-${IBIS_VERSION} wheel created"
else
    echo "      WARNING: ibis-framework wheel may have wrong version"
    ls "${WHEELS_DIR}"/ibis_framework*.whl 2>/dev/null || echo "      No ibis wheel found!"
fi

# Copy wren_engine wheel
cp "${SCRIPT_DIR}/dist/"*.whl "${WHEELS_DIR}/" 2>/dev/null || true

# Remove any source distributions (tar.gz, zip) - we only want wheels
rm -f "${WHEELS_DIR}"/*.tar.gz "${WHEELS_DIR}"/*.zip 2>/dev/null || true

# Install the wren-core-py wheel we built earlier
WREN_CORE_WHEEL=$(ls "${WHEELS_DIR}"/wren_core_py*.whl 2>/dev/null | head -1)
if [[ -n "${WREN_CORE_WHEEL}" ]]; then
    poetry run pip install --force-reinstall "${WREN_CORE_WHEEL}" --quiet
fi

# Count final wheels
WHEEL_COUNT=$(ls -1 ${WHEELS_DIR}/*.whl 2>/dev/null | wc -l)
echo "    ✓ ${WHEEL_COUNT} wheels collected"

# List some key wheels for verification
echo "    Key wheels:"
for pkg in fastapi uvicorn gunicorn pydantic ibis_framework wren_core_py wren_engine; do
    wheel=$(ls "${WHEELS_DIR}"/${pkg}*.whl 2>/dev/null | head -1)
    if [[ -n "$wheel" ]]; then
        echo "      ✓ $(basename $wheel)"
    else
        echo "      ✗ ${pkg} - MISSING!"
    fi
done

# Step 4: Copy application code and resources
echo ""
echo ">>> [4/5] Copying application code..."
mkdir -p "${DIST_DIR}/app"
mkdir -p "${DIST_DIR}/wren"
mkdir -p "${DIST_DIR}/resources"

cp -r "${SCRIPT_DIR}/app/"* "${DIST_DIR}/app/"
cp -r "${SCRIPT_DIR}/wren/"* "${DIST_DIR}/wren/"
cp -r "${SCRIPT_DIR}/resources/"* "${DIST_DIR}/resources/"
echo "    ✓ Application code copied"

# Step 5: Create install and run scripts for target machines
echo ""
echo ">>> [5/5] Creating install/run scripts..."

cat > "${DIST_DIR}/install.sh" << 'INSTALL_EOF'
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
INSTALL_EOF
chmod +x "${DIST_DIR}/install.sh"

# Create run script
cat > "${DIST_DIR}/run.sh" << 'RUN_EOF'
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
RUN_EOF
chmod +x "${DIST_DIR}/run.sh"

# Create systemd service file template
cat > "${DIST_DIR}/ibis-server.service" << 'SERVICE_EOF'
# Systemd service file for ibis-server
# Copy to: /etc/systemd/system/ibis-server.service
# Then: sudo systemctl daemon-reload && sudo systemctl enable --now ibis-server

[Unit]
Description=Wren Engine Ibis Server
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/ibis-server
Environment="PYTHONPATH=/opt/ibis-server"
Environment="REMOTE_FUNCTION_LIST_PATH=/opt/ibis-server/resources/function_list"
Environment="REMOTE_WHITE_FUNCTION_LIST_PATH=/opt/ibis-server/resources/white_function_list"
Environment="PORT=8000"
Environment="WORKERS=2"
ExecStart=/opt/ibis-server/venv/bin/gunicorn app.main:app --bind 0.0.0.0:8000 -k uvicorn.workers.UvicornWorker --workers 2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "    ✓ Scripts created"

# Step 6: Create tarball
echo ""
echo ">>> Creating distributable tarball..."
cd "${SCRIPT_DIR}"
VERSION=$(grep 'version = ' pyproject.toml | head -1 | cut -d'"' -f2)
ARCH=$(uname -m)
TARBALL_NAME="ibis-server-${VERSION}-linux-${ARCH}.tar.gz"
tar -czf "${TARBALL_NAME}" -C "${DIST_DIR}" .

echo ""
echo "==========================================="
echo "  BUILD COMPLETE"
echo "==========================================="
echo ""
echo "Distributable: ${SCRIPT_DIR}/${TARBALL_NAME}"
echo "Size: $(du -h ${TARBALL_NAME} | cut -f1)"
echo "Wheels: $(ls -1 ${WHEELS_DIR}/*.whl 2>/dev/null | wc -l) packages"
echo ""
echo "DEPLOYMENT INSTRUCTIONS:"
echo "------------------------"
echo "1. Copy ${TARBALL_NAME} to target machine"
echo ""
echo "2. Extract:"
echo "   mkdir -p /opt/ibis-server"
echo "   tar -xzf ${TARBALL_NAME} -C /opt/ibis-server"
echo ""
echo "3. Install (creates venv, installs wheels - NO COMPILATION):"
echo "   cd /opt/ibis-server && ./install.sh"
echo ""
echo "4. Run:"
echo "   ./run.sh"
echo ""
echo "TARGET MACHINE REQUIREMENTS:"
echo "  ✓ Python 3.11 (just runtime, no pip/poetry needed after install)"
echo "  ✓ Runtime libs: libpq, libmysqlclient, libodbc (for DB connections)"
echo "  ✗ NO Rust"
echo "  ✗ NO build tools"
echo "  ✗ NO compilation"
echo ""
