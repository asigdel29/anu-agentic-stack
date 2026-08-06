#!/usr/bin/env bash
# install-zeromem.sh — build zeromem and register it as Hermes's memory provider.
#
# History
#   2026-08-06  A. Sigdel  Created.
#
# Usage
#   deploy/install-zeromem.sh [hermes-python]
#
# Separate from bootstrap-pi.sh because this compiles a Rust extension, which
# takes minutes and needs a Python to build against. Wrapping it in the main
# bootstrap would make a re-run of that script slow for no reason.
#
# Idempotent: an existing wheel of the same commit is reused, and the symlink and
# config are written only when they differ.

set -euo pipefail

# Pinned. zeromem is new and single-author, so an unpinned clone means the memory
# layer can change under a re-run with no signal that anything moved.
readonly ZEROMEM_COMMIT=32ac538
readonly REPO=https://github.com/ptaranat/zeromem.git

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PYTHON="${1:-$(command -v python3)}"
BUILD_DIR="${ZEROMEM_BUILD_DIR:-$HOME/.cache/zeromem-build}"

step() { printf '\n== %s ==\n' "$1"; }
ok() { printf '   ok    %s\n' "$1"; }
did() { printf '   done  %s\n' "$1"; }

# Total RAM in MiB, or 0 where it cannot be read. Decides whether the ONNX
# embedder is affordable alongside Hermes and the router.
total_ram_mib() {
    if [ -r /proc/meminfo ]; then
        awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
    else
        echo 0
    fi
}

step "prerequisites"
for tool in cargo git "$PYTHON"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "   FAIL  $tool is required" >&2
        exit 1
    fi
done
ok "cargo, git and $($PYTHON --version) present"

step "source"
if [ -d "$BUILD_DIR/.git" ]; then
    git -C "$BUILD_DIR" fetch -q --depth 1 origin "$ZEROMEM_COMMIT" 2>/dev/null || true
    git -C "$BUILD_DIR" checkout -q "$ZEROMEM_COMMIT"
    ok "reusing $BUILD_DIR at $ZEROMEM_COMMIT"
else
    rm -rf "$BUILD_DIR"
    git clone -q "$REPO" "$BUILD_DIR"
    git -C "$BUILD_DIR" checkout -q "$ZEROMEM_COMMIT"
    did "cloned to $BUILD_DIR at $ZEROMEM_COMMIT"
fi

step "embedder"
ram="$(total_ram_mib)"
# The ONNX model is ~130MB resident on top of Hermes and the router. Below 6GB
# that is not affordable, and a worse embedding that fits beats a better one that
# does not — the same trade the router makes for its own embedder.
if [ "$ram" -ge 6144 ]; then
    USE_MODEL=true
    CARGO_FLAGS=""
    ok "${ram} MiB RAM — building with the ONNX embedder"
else
    USE_MODEL=false
    CARGO_FLAGS="--no-default-features"
    if [ "$ram" -eq 0 ]; then
        ok "RAM unknown — building the hash embedder, which always fits"
    else
        ok "${ram} MiB RAM — hash embedder, skipping the 130MB model"
    fi
fi

step "wheel"
# shellcheck disable=SC2086  # CARGO_FLAGS is a deliberate word-split of flags.
"$PYTHON" -m pip install -q --upgrade maturin >/dev/null 2>&1 || true
if ! "$PYTHON" -m maturin --version >/dev/null 2>&1; then
    echo "   FAIL  maturin unavailable; pip install maturin into $PYTHON" >&2
    exit 1
fi
(
    cd "$BUILD_DIR"
    # shellcheck disable=SC2086
    "$PYTHON" -m maturin build --release $CARGO_FLAGS -m crates/zeromem-py/Cargo.toml
)
wheel="$(find "$BUILD_DIR/target/wheels" -name 'zeromem_py-*.whl' -print -quit)"
[ -n "$wheel" ] || {
    echo "   FAIL  no wheel produced" >&2
    exit 1
}
did "built $(basename "$wheel")"

step "install into Hermes"
"$PYTHON" -m pip install -q --force-reinstall "$wheel"
"$PYTHON" -c 'import zeromem; print("   done  import zeromem works")'

step "plugin"
mkdir -p "$HERMES_HOME/plugins" "$HERMES_HOME/memory"
link="$HERMES_HOME/plugins/zeromem"
target="$BUILD_DIR/hermes/zeromem"
if [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then
    ok "plugin already linked"
else
    ln -sfn "$target" "$link"
    did "linked $link -> $target"
fi

step "configuration"
config="$HERMES_HOME/memory/zeromem.json"
desired="$(printf '{\n  "db_path": "%s/memory/zeromem.db",\n  "use_model": %s\n}\n' "$HERMES_HOME" "$USE_MODEL")"
if [ -f "$config" ] && [ "$(cat "$config")" = "$desired" ]; then
    ok "$config is current"
else
    printf '%s' "$desired" >"$config"
    did "wrote $config (use_model: $USE_MODEL)"
fi

cat <<DONE

zeromem installed. Two steps remain, in $HERMES_HOME/config.yaml:

    memory:
      provider: zeromem

then restart Hermes. Confirm with a question about an earlier session; recall
returns verbatim turns with provenance, and costs no tokens.

If it misbehaves, memory.provider is a one-line swap — Hermes ships mem0,
supermemory and honcho, and nothing else in this stack depends on zeromem.
DONE
