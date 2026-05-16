#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) tmux binary for embedding in CherryLily.app.
# Pinned to a stable version. Bumping the version is a deliberate, reviewed change.

set -euo pipefail

TMUX_VERSION="${TMUX_VERSION:-3.5a}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
# SHA-256 checksums for the pinned source tarballs. Bumping a *_VERSION above
# without also updating the matching *_SHA256 here will fail the integrity check
# below — that is intentional. Recompute with:
#   curl -L <url> | shasum -a 256
TMUX_SHA256="${TMUX_SHA256:-16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951}"
LIBEVENT_SHA256="${LIBEVENT_SHA256:-92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/tmux-build"
OUT_BINARY="${ROOT_DIR}/Frameworks/tmux-cherrylily"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# fetch_and_verify <url> <output-tarball> <expected-sha256>
# Downloads atomically (to .tmp, then mv), retries on transient failures, and
# verifies the SHA-256 before returning. On checksum mismatch the bad tarball
# is deleted and the script exits non-zero.
fetch_and_verify() {
  local url="$1"
  local out="$2"
  local expected="$3"

  if [ ! -f "$out" ]; then
    echo "Downloading $(basename "$out")..."
    curl --fail --location --silent --show-error --retry 3 \
      -o "${out}.tmp" "$url"
    mv "${out}.tmp" "$out"
  fi

  echo "Verifying SHA-256 of $(basename "$out")..."
  if ! echo "${expected}  ${out}" | shasum -a 256 -c - >/dev/null; then
    echo "ERROR: SHA-256 mismatch for ${out}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   $(shasum -a 256 "$out" | awk '{print $1}')" >&2
    echo "Deleting corrupt tarball. Re-run the build to retry." >&2
    rm -f "$out"
    exit 1
  fi
}

build_arch() {
  local arch="$1"
  local prefix="$WORK_DIR/install-$arch"
  local cflags="-arch $arch -mmacosx-version-min=12.0"
  local ldflags="-arch $arch"

  # libevent/tmux's bundled config.sub doesn't know "arm64", but it does know
  # "aarch64". The actual binary architecture is set by -arch in CFLAGS/LDFLAGS,
  # so the --host name only affects autoconf's cross-compile detection.
  local host
  if [ "$arch" = "arm64" ]; then
    host="aarch64-apple-darwin"
  else
    host="${arch}-apple-darwin"
  fi

  rm -rf "$prefix"
  mkdir -p "$prefix"

  # libevent (tmux's only required external dep)
  if [ ! -d "libevent-${LIBEVENT_VERSION}" ]; then
    fetch_and_verify \
      "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz" \
      "libevent-${LIBEVENT_VERSION}.tar.gz" \
      "$LIBEVENT_SHA256"
    tar xf "libevent-${LIBEVENT_VERSION}.tar.gz"
  fi
  pushd "libevent-${LIBEVENT_VERSION}"
  make distclean 2>/dev/null || true
  CFLAGS="$cflags" LDFLAGS="$ldflags" \
    ./configure --prefix="$prefix" --disable-shared --disable-openssl \
                --host="$host" --enable-static
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd

  # tmux
  if [ ! -d "tmux-${TMUX_VERSION}" ]; then
    fetch_and_verify \
      "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" \
      "tmux-${TMUX_VERSION}.tar.gz" \
      "$TMUX_SHA256"
    tar xf "tmux-${TMUX_VERSION}.tar.gz"
  fi
  pushd "tmux-${TMUX_VERSION}"
  make distclean 2>/dev/null || true
  # Note: do NOT pass --enable-static — on macOS tmux's configure rejects it
  # because Apple does not ship static system libraries. We still get a
  # self-contained binary because libevent is built as a .a only (no .dylib),
  # so tmux's link step picks up the static archive automatically.
  CFLAGS="$cflags -I${prefix}/include" \
  LDFLAGS="$ldflags -L${prefix}/lib" \
  PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" \
    ./configure --prefix="$prefix" \
                --host="$host" --disable-utf8proc
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd

  echo "Built tmux for $arch at $prefix/bin/tmux"
}

build_arch arm64
build_arch x86_64

# Lipo into universal binary
mkdir -p "$(dirname "$OUT_BINARY")"
lipo -create \
  "$WORK_DIR/install-arm64/bin/tmux" \
  "$WORK_DIR/install-x86_64/bin/tmux" \
  -output "$OUT_BINARY"

# Verify
file "$OUT_BINARY"
echo "Universal tmux binary: $OUT_BINARY"
