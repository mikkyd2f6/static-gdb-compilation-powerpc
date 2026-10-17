# static-gdb-powerpc

Statically-linked [GDB](https://www.gnu.org/software/gdb/) that runs **natively on
PowerPC Linux machines** — single portable binaries with no shared-library
dependencies, for copying onto POWER servers, embedded boards, or legacy PPC
boxes where you can't install packages.

Three flavors, two variants each:

| Binary | ~Size | Flavor |
|---|---|---|
| `gdb-<ver>-ppc64le-static-nopython` | ~14 MB | 64-bit little-endian (ELFv2) — modern POWER8/9/10 |
| `gdb-<ver>-ppc64le-static-python` | ~20 MB | + embedded CPython 3.12 |
| `gdb-<ver>-ppc32-static-nopython` | ~12 MB | 32-bit big-endian — classic/embedded PowerPC |
| `gdb-<ver>-ppc32-static-python` | ~17 MB | + embedded CPython 3.12 |
| `gdb-<ver>-ppc64be-static-nopython` | ~14 MB | 64-bit big-endian (ELFv1) — legacy POWER |
| `gdb-<ver>-ppc64be-static-python` | ~20 MB | + embedded CPython 3.12 |

Target profile: **glibc 2.40** (needs a reasonably modern kernel on the device).
Check a device with `readelf -h /bin/sh | grep -E 'ELF|Machine'` — the ELF class
(32/64) and byte order (MSB/LSB) tell you which flavor it needs.

## Quick start

Requirements: Ubuntu/Debian-ish **x86_64** host (the build cross-compiles), with
`build-essential`, `curl`, and:

```bash
sudo apt-get install -y \
    libgmp-dev libmpfr-dev libexpat1-dev zlib1g-dev libncurses-dev texinfo \
    gcc-14-powerpc64le-linux-gnu g++-14-powerpc64le-linux-gnu \
    libc6-dev-ppc64el-cross binutils-powerpc64le-linux-gnu \
    gcc-14-powerpc-linux-gnu g++-14-powerpc-linux-gnu \
    libc6-dev-powerpc-cross binutils-powerpc-linux-gnu \
    gcc-14-powerpc64-linux-gnu g++-14-powerpc64-linux-gnu \
    libc6-dev-ppc64-cross binutils-powerpc64-linux-gnu \
    qemu-user-static
```

Then:

```bash
./build.sh
```

Binaries land in `dist/`, full install trees under `install/<triplet>-<variant>/`.
A full build (all three flavors) takes roughly 45–60 minutes on a 20-core
machine. The script is re-runnable: sources, host Python, cross libraries,
cross Pythons, and finished binaries are skipped when already present.

### Options

```bash
GDB_VERSION=16.3     PYTHON_VERSION=3.12.7    # upstream versions
TRIPLETS="powerpc64le-linux-gnu powerpc-linux-gnu powerpc64-linux-gnu"  # subset
VARIANTS="nopython python"                    # subset to build
CROSS_GCC_VER=14    # cross gcc package series on the host
JOBS=$(nproc)       # parallel jobs
BASE=/path/to/dir   # where to place src/deps/build/install/dist (default: repo dir)
```

## Deploying to a device

```bash
scp dist/gdb-16.3-ppc64le-static-nopython root@device:/usr/local/bin/gdb
```

For the **python** variants also copy the data-directory (its path is baked in
at build time; keep the relative layout or pass `--data-directory`):

```bash
scp -r install/powerpc64le-linux-gnu-python/share root@device:/usr/local/
```

## Verifying on an x86_64 host (qemu)

The build script sanity-checks every binary under qemu-user. You can also run a
full end-to-end debug session on your workstation:

```bash
# target program under qemu's gdbserver stub
qemu-ppc64le-static -g 12345 ./my-ppc64le-binary &
qemu-ppc64le-static ./dist/gdb-16.3-ppc64le-static-nopython \
    -batch -ex 'file ./my-ppc64le-binary' -ex 'target remote :12345' \
    -ex 'break main' -ex continue -ex 'info registers pc'
```

## Caveats

- **Thread debugging is limited**: a glibc-static executable cannot `dlopen`
  `libthread_db` (same limitation as any statically linked GDB).
- **Python variant**: extension modules relying on `dlopen` cannot load
  (`import ctypes` fails); pure-Python GDB scripts work. pwndbg/gef will not
  work with a static build.
- Native target only: each flavor debugs its own ABI (ppc64le ELFv2, ppc32,
  ppc64 ELFv1). To cross-debug PowerPC from x86_64 instead, an
  `--enable-targets=all` x86_64 build is a better fit.
- Static glibc 2.40 binaries need a kernel of roughly 3.2 or newer on the device.

## How it works / notable gotchas

1. **Cross toolchain**: Ubuntu's `gcc-14-<triplet>` + `libc6-dev-*-cross`
   packages (static glibc archives included). GDB's support libraries
   (GMP/MPFR — hard requirements of GDB 16 — plus expat, zlib, ncurses) are not
   packaged for cross use, so they are cross-built statically from source.
2. **libtool swallows `-static`**: GDB's final link runs through libtool, which
   consumes a plain `-static` flag and silently produces a dynamic binary. The
   build relinks with `make -C gdb LDFLAGS="-all-static"`.
3. **qemu-user as the Python bridge**: GDB's configure must *execute* the
   Python it links against. The cross-built Python (static libpython, dynamic
   glibc) is wrapped in a `qemu-<arch>-static -L /usr/<triplet>` script passed
   to `--with-python=` — configure runs the target interpreter under emulation
   and link-tests the real cross `libpython3.12.a`.
4. **CPython 3.12 cross quirks**: `--with-build-python=<host python>` is
   required; `ac_cv_buggy_getaddrinfo=no` (a runtime test false-fails when
   cross-compiling); out-of-tree builds require a pristine source tree, which
   is why every Python build here (host and cross) is out-of-tree.
5. **ncurses widec**: cross ncurses installs only the widec flavor
   (`libncursesw.a`), while readline/TUI look for `-lncurses`/`-ltinfo`; the
   build provides symlink aliases (ABI-compatible for readline's use).

Build layout (all gitignored): `src/`, `deps/` (host + cross Pythons and
libraries), `build-*/`, `install/`, `dist/`.

## License

GDB is GPLv3; statically-linked GDB binaries are derivative works, so if you
distribute the binaries you must offer the corresponding source (this repo plus
the pinned upstream versions is a reasonable way to do that). No license is
claimed over these build files — add one of your choosing before publishing.
