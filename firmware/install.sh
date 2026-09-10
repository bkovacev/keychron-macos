#!/usr/bin/env bash
# Apply the battery-reporting and keyboard-control features to a Keychron QMK
# checkout and build it.
#
#   ./install.sh                       # clone into ./qmk, patch, build ansi/white:via
#   ./install.sh --repo ~/qmk_firmware # patch an existing checkout instead
#   ./install.sh --target keychron/k10_pro/ansi/rgb:via
#   ./install.sh --no-build            # patch only
#
# Re-running is safe: every edit is skipped if it is already present.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/qmk"
TARGET="keychron/k10_pro/ansi/white:via"   # PID 0x02A3, the connected keyboard
BRANCH="bluetooth_playground"
DO_BUILD=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)     REPO="$2"; shift 2 ;;
        --target)   TARGET="$2"; shift 2 ;;
        --branch)   BRANCH="$2"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checkout
if [[ ! -d "$REPO/.git" ]]; then
    say "cloning Keychron/qmk_firmware ($BRANCH) into $REPO"
    git clone --depth 1 --single-branch --branch "$BRANCH" \
        https://github.com/Keychron/qmk_firmware.git "$REPO"
fi

[[ -d "$REPO/keyboards/keychron/bluetooth" ]] || \
    die "$REPO does not look like a Keychron QMK checkout (no keyboards/keychron/bluetooth)"

BOARD_DIR="$REPO/keyboards/${TARGET%%:*}"
BOARD_DIR="${BOARD_DIR%/ansi/*}"; BOARD_DIR="${BOARD_DIR%/iso/*}"; BOARD_DIR="${BOARD_DIR%/jis/*}"
BOARD_NAME="$(basename "$BOARD_DIR")"
BOARD_C="$BOARD_DIR/$BOARD_NAME.c"

[[ -f "$BOARD_C" ]] || die "cannot find board source $BOARD_C"

# ---------------------------------------------------------------- copy sources
say "installing feature sources into keyboards/keychron/bluetooth"
cp "$HERE/src/battery_report.c"   "$HERE/src/battery_report.h" \
   "$HERE/src/keyboard_control.c" "$HERE/src/keyboard_control.h" \
   "$REPO/keyboards/keychron/bluetooth/"

# ---------------------------------------------------------------- edits
say "wiring it up ($BOARD_NAME)"
BOARD_C="$BOARD_C" REPO="$REPO" python3 "$HERE/wire.py"

# ---------------------------------------------------------------- build
if [[ "$DO_BUILD" == "0" ]]; then
    say "patched, skipping build (--no-build)"
    exit 0
fi

# A toolchain extracted from the Homebrew cask payload lands here; see README.
if ! command -v arm-none-eabi-gcc >/dev/null && [[ -x "$HOME/.local/opt/arm-gnu-toolchain/bin/arm-none-eabi-gcc" ]]; then
    export PATH="$HOME/.local/opt/arm-gnu-toolchain/bin:$PATH"
fi

command -v arm-none-eabi-gcc >/dev/null || die \
"arm-none-eabi-gcc not found. Install it with:

    brew install --cask gcc-arm-embedded

That runs a .pkg and asks for your password. To avoid sudo entirely, see
'Installing the toolchain without sudo' in the README.

Then re-run this script, or pass --no-build to patch only."

# This fork predates QMK's bundled bin/qmk wrapper, and its CLI code does not
# work with milc 2.x. Bootstrap a private, pinned environment rather than
# depending on whatever qmk happens to be installed system-wide.
if ! command -v qmk >/dev/null; then
    TOOLS="$HERE/.toolchain"
    if [[ ! -x "$TOOLS/bin/qmk" ]]; then
        say "bootstrapping a private qmk CLI (venv + pinned milc)"
        python3 -m venv "$TOOLS/venv"
        "$TOOLS/venv/bin/pip" install -q --upgrade pip
        "$TOOLS/venv/bin/pip" install -q -r "$REPO/requirements.txt" "milc<2"

        mkdir -p "$TOOLS/bin"
        cat > "$TOOLS/bin/qmk" <<SHIM
#!$TOOLS/venv/bin/python3
"""Stand-in for QMK's bin/qmk, which this fork does not ship."""
import os, sys
from pathlib import Path

qmk_home = Path(os.environ["QMK_HOME"]).resolve()
sys.path.append(str(qmk_home / "lib" / "python"))

# The CLI resolves user-supplied paths against ORIG_CWD, then works from the
# repository root.
os.environ["ORIG_CWD"] = os.getcwd()
os.chdir(qmk_home)

import milc  # noqa

milc.cli.milc_options(name="qmk", author="QMK", version=os.environ.get("QMK_VERSION", "unknown"))

import milc.subcommand.config  # noqa
import qmk.cli  # noqa

if __name__ == "__main__":
    sys.exit(milc.cli())
SHIM
        chmod +x "$TOOLS/bin/qmk"
    fi
    export PATH="$TOOLS/bin:$TOOLS/venv/bin:$PATH"
fi

export QMK_HOME="$(cd "$REPO" && pwd)"

if [[ ! -f "$REPO/lib/chibios/os/hal/hal.mk" ]]; then
    say "fetching submodules (chibios & friends, a few hundred MB)"
    git -C "$REPO" submodule update --init --recursive --depth 1
fi

say "building $TARGET"
# SKIP_GIT: submodules are managed above, and the in-recipe sync is slow and
# noisy on a shallow clone.
make -C "$REPO" SKIP_GIT=yes "$TARGET"

say "done"
ls -la "$REPO"/*.bin 2>/dev/null || true
