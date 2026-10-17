#!/usr/bin/env bash
#
# Build statically-linked GDB natively for PowerPC Linux, in three flavors:
#   powerpc64le-linux-gnu  (ppc64le, 64-bit little-endian, ELFv2 — modern POWER)
#   powerpc-linux-gnu      (ppc32, 32-bit big-endian — classic/embedded)
#   powerpc64-linux-gnu    (ppc64be, 64-bit big-endian, ELFv1 — legacy POWER)
#
# Per triplet, two variants:
#   nopython : lean on-target debugger, TUI included, no Python scripting
#   python   : additionally embeds cross-built static CPython 3.12
#
# Outputs:
#   dist/gdb-<ver>-<ppc64le|ppc32|ppc64be>-static-<variant>   stripped static binaries
#   install/<triplet>-<variant>/                              full install trees
#
# Runs on an x86_64 Ubuntu/Debian host and cross-compiles everything.
# qemu-user is used to run the target Python during GDB's configure step and
# to sanity-check the resulting binaries. See README.md for details.
#
set -euo pipefail

GDB_VERSION="${GDB_VERSION:-16.3}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.7}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
MPFR_VERSION="${MPFR_VERSION:-4.2.1}"
EXPAT_VERSION="${EXPAT_VERSION:-2.6.4}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
NCURSES_VERSION="${NCURSES_VERSION:-6.5}"

TRIPLETS="${TRIPLETS:-powerpc64le-linux-gnu powerpc-linux-gnu powerpc64-linux-gnu}"
VARIANTS="${VARIANTS:-nopython python}"
CROSS_GCC_VER="${CROSS_GCC_VER:-14}"
JOBS="${JOBS:-$(nproc)}"

BASE="${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD=x86_64-linux-gnu
SRC="$BASE/src"
DEPS="$BASE/deps"
DIST="$BASE/dist"
mkdir -p "$SRC" "$DEPS" "$DIST"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

qemu_for_triplet() {
    case "$1" in
        powerpc64le-*) echo qemu-ppc64le-static ;;
        powerpc64-*)   echo qemu-ppc64-static ;;
        powerpc-*)     echo qemu-ppc-static ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

short_for_triplet() {
    case "$1" in
        powerpc64le-*) echo ppc64le ;;
        powerpc64-*)   echo ppc64be ;;
        powerpc-*)     echo ppc32 ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# 0. Host dependencies
# --------------------------------------------------------------------------
check_host_deps() {
    local missing=()
    local t f

    for f in /usr/include/expat.h:libexpat1-dev /usr/include/zlib.h:zlib1g-dev \
             /usr/include/mpfr.h:libmpfr-dev; do
        [ -e "${f%%:*}" ] || missing+=("${f##*:}")
    done
    if [ ! -e /usr/include/gmp.h ] && [ ! -e /usr/include/x86_64-linux-gnu/gmp.h ]; then
        missing+=(libgmp-dev)
    fi
    [ -e /usr/lib/x86_64-linux-gnu/libtinfo.a ] || missing+=(libncurses-dev)
    command -v makeinfo >/dev/null || missing+=(texinfo)
    command -v m4 >/dev/null || missing+=(m4)

    for t in $TRIPLETS; do
        command -v "$t-gcc-$CROSS_GCC_VER" >/dev/null || missing+=("gcc-$CROSS_GCC_VER-$t")
        command -v "$t-g++-$CROSS_GCC_VER" >/dev/null || missing+=("g++-$CROSS_GCC_VER-$t")
        command -v "$t-strip" >/dev/null || missing+=("binutils-$t")
        [ -e "/usr/$t/lib/libc.a" ] || case "$t" in
            powerpc64le-*) missing+=(libc6-dev-ppc64el-cross) ;;
            powerpc64-*)   missing+=(libc6-dev-ppc64-cross) ;;
            powerpc-*)     missing+=(libc6-dev-powerpc-cross) ;;
        esac
        command -v "$(qemu_for_triplet "$t")" >/dev/null || missing+=(qemu-user-static)
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing host packages: ${missing[*]}" >&2
        echo "Install them with:" >&2
        echo "  sudo apt-get install -y ${missing[*]}" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# 1. Fetch and unpack sources
# --------------------------------------------------------------------------
fetch_sources() {
    cd "$SRC"
    [ -f "gdb-$GDB_VERSION.tar.xz" ] || \
        curl -fsSLO "https://ftp.gnu.org/gnu/gdb/gdb-$GDB_VERSION.tar.xz"
    [ -f "Python-$PYTHON_VERSION.tgz" ] || \
        curl -fsSLO "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"
    [ -f "gmp-$GMP_VERSION.tar.xz" ] || \
        curl -fsSLO "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
    [ -f "mpfr-$MPFR_VERSION.tar.xz" ] || \
        curl -fsSLO "https://ftp.gnu.org/gnu/mpfr/mpfr-$MPFR_VERSION.tar.xz"
    [ -f "expat-$EXPAT_VERSION.tar.xz" ] || \
        curl -fsSLO "https://github.com/libexpat/libexpat/releases/download/R_2_6_$(echo "$EXPAT_VERSION" | cut -d. -f3)/expat-$EXPAT_VERSION.tar.xz"
    [ -f "zlib-$ZLIB_VERSION.tar.xz" ] || \
        curl -fsSLO "https://zlib.net/zlib-$ZLIB_VERSION.tar.xz" || \
        curl -fsSLO "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz"
    [ -f "ncurses-$NCURSES_VERSION.tar.gz" ] || \
        curl -fsSLO "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz"

    local d
    for d in "gdb-$GDB_VERSION" "gmp-$GMP_VERSION" \
             "mpfr-$MPFR_VERSION" "expat-$EXPAT_VERSION" "ncurses-$NCURSES_VERSION"; do
        [ -d "$d" ] || tar xf "$d".tar.*
    done
    [ -d "Python-$PYTHON_VERSION" ] || tar xf "Python-$PYTHON_VERSION.tgz"
    [ -d "zlib-$ZLIB_VERSION" ] || tar xf "zlib-$ZLIB_VERSION".tar.*
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 2. Host CPython (build-python twin for the cross builds; also used to keep
#    versions in sync). Built OUT-OF-TREE so the source tree stays pristine
#    for the cross builds (CPython refuses VPATH builds from a dirty tree).
# --------------------------------------------------------------------------
build_host_python() {
    [ -x "$DEPS/python/bin/python3.12" ] && { log "Host Python already built"; return; }

    log "Building host CPython $PYTHON_VERSION"
    mkdir -p "$BASE/build-host-python"
    cd "$BASE/build-host-python"
    "$SRC/Python-$PYTHON_VERSION/configure" \
        --prefix="$DEPS/python" --disable-shared --without-ensurepip
    make -j"$JOBS"
    make install
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 3. Cross support libraries (static archives) per triplet
# --------------------------------------------------------------------------
build_cross_libs() {
    local T=$1
    local P=$DEPS/cross/$T
    local W=$BASE/build-crosslibs-$T
    local CC=$T-gcc-$CROSS_GCC_VER CXX=$T-g++-$CROSS_GCC_VER
    local AR=$T-ar RANLIB=$T-ranlib

    [ -f "$P/lib/libgmp.a" ] && [ -f "$P/lib/libncursesw.a" ] && \
        { log "Cross libs for $T already built"; return; }

    log "Building cross libraries for $T"
    rm -rf "$W"; mkdir -p "$W"

    mkdir "$W/gmp" && cd "$W/gmp"
    CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
        "$SRC/gmp-$GMP_VERSION/configure" --build=$BUILD --host=$T \
        --prefix=$P --disable-shared --enable-static --disable-assembly
    make -j"$JOBS" && make install

    mkdir "$W/mpfr" && cd "$W/mpfr"
    CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
        "$SRC/mpfr-$MPFR_VERSION/configure" --build=$BUILD --host=$T \
        --prefix=$P --disable-shared --enable-static --with-gmp=$P
    make -j"$JOBS" && make install

    mkdir "$W/expat" && cd "$W/expat"
    CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
        "$SRC/expat-$EXPAT_VERSION/configure" --build=$BUILD --host=$T \
        --prefix=$P --disable-shared --enable-static \
        --without-docbook --without-examples --without-tests
    make -j"$JOBS" && make install

    cp -a "$SRC/zlib-$ZLIB_VERSION" "$W/zlib" && cd "$W/zlib"
    CHOST=$T CC=$CC AR=$AR RANLIB=$RANLIB ./configure --prefix=$P --static
    make -j"$JOBS" && make install

    mkdir "$W/ncurses" && cd "$W/ncurses"
    BUILD_CC=gcc CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
        "$SRC/ncurses-$NCURSES_VERSION/configure" --build=x86_64-pc-linux-gnu --host=$T \
        --prefix=$P --disable-shared --enable-static \
        --without-progs --without-ada --without-manpages --disable-db-install \
        --disable-stripping --enable-widec
    make -j"$JOBS" && make install

    # ncurses installs only the widec flavor; readline/TUI look for the plain
    # names — provide them as symlinks.
    ln -sf libncursesw.a "$P/lib/libncurses.a"
    ln -sf libncursesw.a "$P/lib/libtinfo.a"
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 4. Cross CPython + qemu wrapper (per triplet)
# --------------------------------------------------------------------------
build_cross_python() {
    local T=$1
    local P=$DEPS/cross/$T
    local QEMU
    QEMU=$(qemu_for_triplet "$T")

    [ -x "$P/python3.12-qemu" ] && { log "Cross Python for $T already built"; return; }

    log "Building cross CPython $PYTHON_VERSION for $T"
    mkdir -p "$BASE/build-python-$T"
    cd "$BASE/build-python-$T"
    CC=$T-gcc-$CROSS_GCC_VER AR=$T-ar RANLIB=$T-ranlib \
        "$SRC/Python-$PYTHON_VERSION/configure" \
        --build=$BUILD --host=$T \
        --prefix=$P/python --disable-shared --without-ensurepip \
        --with-build-python="$DEPS/python/bin/python3.12" \
        ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
        ac_cv_buggy_getaddrinfo=no
    make -j"$JOBS"
    make install
    cd "$BASE"

    # The cross python binary is linked against the cross glibc; run it under
    # qemu with the Ubuntu sysroot. GDB's configure executes this interpreter
    # to query sysconfig and link-tests the real cross libpython3.12.a.
    printf '#!/bin/sh\nexec %s -L /usr/%s %s/python/bin/python3.12 "$@"\n' \
        "$QEMU" "$T" "$P" > "$P/python3.12-qemu"
    chmod +x "$P/python3.12-qemu"
    "$P/python3.12-qemu" --version
}

# --------------------------------------------------------------------------
# 5. GDB variant build (cross, native-on-target)
# --------------------------------------------------------------------------
build_gdb() {
    local T=$1 variant=$2
    local short
    short=$(short_for_triplet "$T")
    local P=$DEPS/cross/$T
    local bdir="$BASE/build-$T-$variant"
    local prefix="$BASE/install/$T-$variant"
    local out="$DIST/gdb-$GDB_VERSION-$short-static-$variant"
    local pyflag

    case "$variant" in
        nopython) pyflag="--without-python" ;;
        python)   pyflag="--with-python=$P/python3.12-qemu" ;;
    esac

    log "Building GDB $GDB_VERSION for $T ($variant)"
    [ -x "$out" ] && { log "$out already built"; return; }
    mkdir -p "$bdir"
    cd "$bdir"

    CC=$T-gcc-$CROSS_GCC_VER CXX=$T-g++-$CROSS_GCC_VER AR=$T-ar RANLIB=$T-ranlib \
        "$SRC/gdb-$GDB_VERSION/configure" \
        --build=$BUILD --host=$T --target=$T \
        --prefix="$prefix" \
        $pyflag \
        --without-guile --disable-nls \
        --with-gmp=$P --with-mpfr=$P \
        CPPFLAGS="-I$P/include -I$P/include/ncursesw -I$P/python/include/python3.12" \
        LDFLAGS="-static -L$P/lib -L$P/python/lib"

    make -j"$JOBS" MAKEINFO=true all-gdb

    # GDB's final link goes through libtool, which silently consumes a plain
    # "-static" and produces a *dynamic* binary. Relink fully static:
    rm -f gdb/gdb
    make -C gdb LDFLAGS="-all-static" MAKEINFO=true

    make -C gdb MAKEINFO=true install
    cd "$BASE"

    cp "$prefix/bin/gdb" "$out"
    $T-strip "$out"
}

# --------------------------------------------------------------------------
# 6. Sanity check the results (under qemu)
# --------------------------------------------------------------------------
verify() {
    log "Results"
    local t variant short QEMU b
    for t in $TRIPLETS; do
        short=$(short_for_triplet "$t")
        QEMU=$(qemu_for_triplet "$t")
        for variant in $VARIANTS; do
            b="$DIST/gdb-$GDB_VERSION-$short-static-$variant"
            [ -e "$b" ] || continue
            file "$b" | sed 's/^/  /'
            timeout 120 "$QEMU" "$b" --version | head -1 | sed 's/^/  /'
            if [ "$variant" = python ]; then
                timeout 300 "$QEMU" "$b" -batch \
                    -ex 'python import sys; print("  embedded:", sys.version.split()[0])' || true
            fi
        done
    done
}

main() {
    check_host_deps
    fetch_sources
    build_host_python

    local t variant
    for t in $TRIPLETS; do
        build_cross_libs "$t"
        for variant in $VARIANTS; do
            [ "$variant" = python ] && build_cross_python "$t"
            build_gdb "$t" "$variant"
        done
    done

    verify
    log "Done. Binaries in $DIST"
}

main "$@"
