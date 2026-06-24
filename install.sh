#!/bin/sh
# install.sh — download and install the `openlm` OpenLM installer CLI.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uttam-openlm/helmcharts/main/install.sh | sh
#
# Environment overrides:
#   OPENLM_REPO         GitHub owner/repo to download from (default: uttam-openlm/helmcharts)
#   OPENLM_VERSION      version to install, e.g. 1.2.3 (default: latest installer release)
#   OPENLM_INSTALL_DIR  install directory (default: /usr/local/bin, falls back to $HOME/.local/bin)
set -eu

REPO="${OPENLM_REPO:-uttam-openlm/helmcharts}"
INSTALL_DIR="${OPENLM_INSTALL_DIR:-/usr/local/bin}"
BIN="openlm"

err() { echo "error: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

# --- Prerequisites -----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
have tar || err "tar is required"
if have curl; then DL="curl -fsSL"; DLO="curl -fsSL -o"; else
  if have wget; then DL="wget -qO-"; DLO="wget -qO"; else
    err "need curl or wget to download"
  fi
fi

# --- Detect OS / ARCH (must match GoReleaser archive names) ------------------
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  linux)  os=linux  ;;
  darwin) os=darwin ;;
  *) err "unsupported OS '$os' (supported: linux, darwin). On Windows, download the .zip from https://github.com/$REPO/releases" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64)   arch=amd64 ;;
  aarch64 | arm64)  arch=arm64 ;;
  *) err "unsupported architecture '$arch' (supported: amd64, arm64)" ;;
esac

# --- Resolve version ---------------------------------------------------------
version="${OPENLM_VERSION:-}"
if [ -z "$version" ]; then
  info "Resolving latest ${BIN} release from ${REPO}..."
  api="https://api.github.com/repos/${REPO}/releases/latest"
  version=$($DL "$api" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' \
    | head -n 1 \
    | sed -E 's/.*"v([^"]+)".*/\1/')
  [ -n "$version" ] || err "could not find a release in ${REPO} (set OPENLM_VERSION to install a specific version)"
fi
version="${version#v}"   # tolerate a leading 'v' in OPENLM_VERSION
tag="v${version}"

asset="openlm_${version}_${os}_${arch}.tar.gz"
base="https://github.com/${REPO}/releases/download/${tag}"

info "Installing openlm v${version} (${os}/${arch}) from ${REPO}..."

# --- Download + verify + extract in a temp dir -------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086
$DLO "$tmp/$asset" "$base/$asset" || err "download failed: $base/$asset"
# shellcheck disable=SC2086
$DLO "$tmp/checksums.txt" "$base/checksums.txt" 2>/dev/null || info "warn: checksums.txt unavailable — skipping verification"

if [ -f "$tmp/checksums.txt" ]; then
  want=$(grep " $asset\$" "$tmp/checksums.txt" | awk '{print $1}')
  if [ -n "$want" ]; then
    if have sha256sum; then got=$(sha256sum "$tmp/$asset" | awk '{print $1}');
    elif have shasum;  then got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}');
    else got=""; info "warn: no sha256 tool found — skipping verification"; fi
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      err "checksum mismatch for $asset (want $want, got $got)"
    fi
    [ -n "$got" ] && info "Checksum OK."
  fi
fi

tar xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/$BIN" ] || err "archive did not contain '$BIN'"
chmod +x "$tmp/$BIN"

# --- Install (sudo only if needed; fall back to ~/.local/bin) ----------------
install_to() {
  dir="$1"
  if [ -w "$dir" ] || { [ ! -e "$dir" ] && mkdir -p "$dir" 2>/dev/null; }; then
    mv "$tmp/$BIN" "$dir/$BIN" && echo "$dir/$BIN"
    return 0
  fi
  return 1
}

dest=""
if dest=$(install_to "$INSTALL_DIR"); then :;
elif have sudo && sudo mv "$tmp/$BIN" "$INSTALL_DIR/$BIN" 2>/dev/null; then
  dest="$INSTALL_DIR/$BIN"
elif dest=$(install_to "$HOME/.local/bin"); then
  info "note: $INSTALL_DIR not writable — installed to \$HOME/.local/bin instead"
else
  err "could not write to $INSTALL_DIR or \$HOME/.local/bin (set OPENLM_INSTALL_DIR)"
fi

info ""
info "Installed openlm to $dest"

# --- Add install dir to PATH if not already there ----------------------------
install_dir="$(dirname "$dest")"
case ":$PATH:" in
  *":${install_dir}:"*) : ;;  # already on PATH
  *)
    # Detect the user's shell profile and append an export line
    profile=""
    case "${SHELL:-}" in
      */zsh)  profile="$HOME/.zshrc" ;;
      */fish) profile="$HOME/.config/fish/config.fish" ;;
      *)      profile="$HOME/.bashrc" ;;
    esac
    if [ -n "$profile" ]; then
      if [ "${SHELL:-}" = "*/fish" ]; then
        line="fish_add_path $install_dir"
      else
        line="export PATH=\"${install_dir}:\$PATH\""
      fi
      printf '\n# openlm installer\n%s\n' "$line" >> "$profile"
      info "Added $install_dir to PATH in $profile"
      info "Run:  export PATH=\"${install_dir}:\$PATH\"  (or open a new shell)"
    fi
  ;;
esac

# --- Runtime prerequisites (non-fatal) + next steps --------------------------
have kubectl || info "note: 'kubectl' not found on PATH — openlm needs it at runtime"
have helm    || info "note: 'helm' not found on PATH — openlm needs it at runtime"
info ""
info "Next steps:"
info "  openlm pull      # download the openlm_mono chart"
info "  openlm setup     # run the interactive installer"
