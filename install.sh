#!/bin/sh
# zq installer — https://github.com/Enriquefft/zq
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Enriquefft/zq/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --prefix /usr/local/bin --version 0.1.0
#
# Environment variables:
#   ZQ_VERSION     — version to install (default: latest)
#   ZQ_INSTALL_DIR — installation directory (default: $HOME/.local/bin)

set -eu

REPO="Enriquefft/zq"
INSTALL_DIR="${ZQ_INSTALL_DIR:-}"
VERSION="${ZQ_VERSION:-}"
BASE_URL="https://github.com/${REPO}/releases"

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Options:
  --prefix DIR    Installation directory (default: \$HOME/.local/bin)
  --version VER   Version to install (default: latest)
  --help          Show this help
EOF
}

info() { printf '  \033[1;34m>\033[0m %s\n' "$1"; }
err()  { printf '  \033[1;31merror\033[0m: %s\n' "$1" >&2; exit 1; }

need() {
    if ! command -v "$1" > /dev/null 2>&1; then
        err "required command not found: $1"
    fi
}

download() {
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget > /dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        err "curl or wget is required"
    fi
}

cleanup() {
    if [ -n "${TMPDIR_CREATED:-}" ] && [ -d "${TMPDIR_CREATED}" ]; then
        rm -rf "${TMPDIR_CREATED}"
    fi
}
trap cleanup EXIT

# ── Parse args ────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            shift
            INSTALL_DIR="$1"
            ;;
        --version)
            shift
            VERSION="$1"
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            err "unknown option: $1"
            ;;
    esac
    shift
done

# ── Detect platform ──────────────────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux"   ;;
        Darwin*) echo "macos"   ;;
        FreeBSD) echo "freebsd" ;;
        *)       err "unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              err "unsupported architecture: $(uname -m)" ;;
    esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

# ── Resolve version ──────────────────────────────────────────────────────────

if [ -z "$VERSION" ]; then
    info "fetching latest version..."
    if command -v curl > /dev/null 2>&1; then
        VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"
    elif command -v wget > /dev/null 2>&1; then
        VERSION="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"
    fi
    if [ -z "$VERSION" ]; then
        err "could not determine latest version — set ZQ_VERSION or use --version"
    fi
fi

# Strip leading 'v' if present
VERSION="$(echo "$VERSION" | sed 's/^v//')"

# ── Set install directory ─────────────────────────────────────────────────────

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
fi
mkdir -p "$INSTALL_DIR"

# ── Download & verify ─────────────────────────────────────────────────────────

ARCHIVE="zq-${VERSION}-${OS}-${ARCH}.tar.gz"
DOWNLOAD_URL="${BASE_URL}/download/v${VERSION}/${ARCHIVE}"
CHECKSUMS_URL="${BASE_URL}/download/v${VERSION}/checksums-sha256.txt"

TMPDIR_CREATED="$(mktemp -d)"
cd "$TMPDIR_CREATED"

info "downloading zq v${VERSION} for ${OS}/${ARCH}..."
download "$DOWNLOAD_URL" "$ARCHIVE"
download "$CHECKSUMS_URL" "checksums-sha256.txt"

info "verifying checksum..."
EXPECTED="$(grep "$ARCHIVE" checksums-sha256.txt | awk '{print $1}')"
if [ -z "$EXPECTED" ]; then
    err "archive not found in checksums file"
fi

if command -v sha256sum > /dev/null 2>&1; then
    ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
elif command -v shasum > /dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
else
    err "sha256sum or shasum is required for verification"
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    err "checksum mismatch: expected $EXPECTED, got $ACTUAL"
fi

# ── Install ───────────────────────────────────────────────────────────────────

info "extracting to ${INSTALL_DIR}..."
tar -xzf "$ARCHIVE"
install -m 755 zq "$INSTALL_DIR/zq"

info "installed zq v${VERSION} to ${INSTALL_DIR}/zq"

# ── PATH check ────────────────────────────────────────────────────────────────

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        printf '\n  \033[1;33mwarning\033[0m: %s is not in your PATH\n' "$INSTALL_DIR"
        printf '  Add it with:\n'
        printf '    export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
        ;;
esac
