#!/bin/sh
# Builds a tmux binary whose only dynamic dependencies are macOS system
# libraries (libSystem, libncurses, libresolv), by linking libevent
# statically. Output: Resources/bin/tmux, which the app prefers over any
# Homebrew tmux so users don't need `brew install tmux`.
#
# Usage: scripts/build-tmux.sh [tmux-version] [libevent-version]
set -eu

TMUX_VERSION="${1:-3.7c}"
LIBEVENT_VERSION="${2:-2.1.13-stable}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/tmux-static"
PREFIX="$WORK/prefix"
OUT_DIR="$ROOT/Resources/bin"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=14.0

mkdir -p "$WORK" "$PREFIX" "$OUT_DIR"
cd "$WORK"

fetch() { # url dest
  [ -f "$2" ] || curl -fsSL -o "$2" "$1"
}

# --- libevent (static) -------------------------------------------------
LE_TAR="libevent-$LIBEVENT_VERSION.tar.gz"
fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/$LE_TAR" "$LE_TAR"
if [ ! -f "$PREFIX/lib/libevent_core.a" ]; then
  rm -rf "libevent-$LIBEVENT_VERSION"
  tar xzf "$LE_TAR"
  cd "libevent-$LIBEVENT_VERSION"
  ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-openssl --disable-mbedtls --disable-libevent-regress \
    --disable-samples --disable-debug-mode >configure.log 2>&1
  make -j"$JOBS" >make.log 2>&1
  make install >install.log 2>&1
  cd "$WORK"
fi

# --- tmux ---------------------------------------------------------------
TMUX_TAR="tmux-$TMUX_VERSION.tar.gz"
fetch "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/$TMUX_TAR" "$TMUX_TAR"
rm -rf "tmux-$TMUX_VERSION"
tar xzf "$TMUX_TAR"
cd "tmux-$TMUX_VERSION"

# Always the macOS system ncurses: a static Homebrew ncursesw bakes in
# /opt/homebrew/.../terminfo and fails with "can't find terminfo database"
# on machines without Homebrew's ncurses.
NCURSES_CFLAGS=""
NCURSES_LIBS="-lncurses"

# Keep pkg-config from discovering Homebrew's libevent/utf8proc/jemalloc.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
./configure --prefix="$PREFIX" --disable-utf8proc --disable-jemalloc \
  LIBEVENT_CFLAGS="-I$PREFIX/include" \
  LIBEVENT_LIBS="$PREFIX/lib/libevent_core.a" \
  LIBNCURSES_CFLAGS="$NCURSES_CFLAGS" \
  LIBNCURSES_LIBS="$NCURSES_LIBS" \
  >configure.log 2>&1
make -j"$JOBS" >make.log 2>&1

cp tmux "$OUT_DIR/tmux"
strip "$OUT_DIR/tmux"
chmod 755 "$OUT_DIR/tmux"

echo "Built $OUT_DIR/tmux ($("$OUT_DIR/tmux" -V))"
echo "Dynamic dependencies:"
otool -L "$OUT_DIR/tmux" | tail -n +2
if otool -L "$OUT_DIR/tmux" | tail -n +2 | grep -qv '/usr/lib/'; then
  echo "ERROR: non-system dylib dependency present; removing output" >&2
  rm -f "$OUT_DIR/tmux"
  exit 1
fi
