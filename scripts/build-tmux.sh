#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) tmux binary for embedding in CherryLily.app.
# Pinned to a stable version. Bumping the version is a deliberate, reviewed change.

set -euo pipefail

TMUX_VERSION="${TMUX_VERSION:-3.5a}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/tmux-build"
OUT_BINARY="${ROOT_DIR}/Frameworks/tmux-cherrylily"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

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
    curl -L -o "libevent-${LIBEVENT_VERSION}.tar.gz" \
      "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"
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
    curl -L -o "tmux-${TMUX_VERSION}.tar.gz" \
      "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
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
