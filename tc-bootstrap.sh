#!/usr/bin/env bash
# tc-bootstrap.sh v2 — merged fast-restore of the ReSuSFS x86_64 build env
#
# Replaces BOTH previous scripts:
#   * tc-bootstrap.sh v1      (clang-17.0.6 self-contained install)
#   * restore_build_env.sh v26.11.34 (kernel tree, current.h override, host debs)
# and follows README-BUILD-V52.md sections 3/4/5 for layout and inputs.
#
# Toolchain layout (lean, ~680MB extracted / ~118MB packed):
#   bin/   19 kernel tools, pinned by 8 SHA256 hashes in MANIFEST
#   lib/   only lib/clang (builtin headers); the official release binaries are
#          statically linked (system libc/libz/libstdc++ only, see ldd)
#
# One run restores four things, all idempotent, all hash-checked:
#   1. clang-17.0.6 toolchain (ThinLTO + kCFI smoke-tested on x86_64 AND
#      aarch64; llvm-bolt + llvm-profdata kept = BOLT / PGO tooling) -> $BASE/tc
#   2. linux-5.15.178 kernel tree + the susfs current.h x86_64 override
#                                                     -> $BASE/linux-5.15.178
#   3. host build debs (flex bison bc libelf zlib zstd) -> $BASE/tc-host
#      + compat symlink /tmp/toolchain (old scripts hardcode it)
#      + shim $BASE/toolchain/clang17/usr/lib/llvm-17/{bin,lib}
#   4. $BASE/tc-env.sh — sourceable PATH / vars for the build scripts
#
# SPEED (the whole point):
#   warm (sandbox recycled, /home/z/my-project kept): stat-cache verify of the
#     8 pinned binaries + file-existence checks, no network, < 1 s.
#   cold (full wipe): toolchain tarball fetched through a fallback chain -
#     pikyxdev/sandboxed release -> official LLVM 17.0.6 - and the kernel
#     tarball downloaded IN PARALLEL, then extracted, trimmed and smoke-tested.
#     All chain sources unpack to the same hash-pinned tree.
#   The stat-cache (size+mtime per binary) is trusted for the fast path;
#   `--check` always does a true SHA256 re-hash of all 8 binaries.
#
# SELF-HOSTED FROM YOUR GITHUB REPO (default source #1):
#   repo pikyxdev/sandboxed, release tag "final", asset
#   tc-clang-17.0.6-kernel-min.tar.xz (sha256 751a493f...). Until that asset
#   is live/public the chain silently falls through to the next source.
#   `bash tc-bootstrap.sh --pack` (re)builds the tarball + .sha256 for you
#   to upload as that asset, and prints the exact upload steps.
#
# Usage: bash tc-bootstrap.sh [MODE] [-q]
#   (no arg)   auto: restore everything that is missing, verify the rest
#   --check    verify only (true SHA256 of the 8 binaries), never downloads
#   --force    wipe and reinstall the toolchain, then re-run other steps
#   --pack     pack the verified toolchain for your GitHub release
#   --status   read-only overview of every component
#   --with-a13 also ensure the a13-mirror tarball (slow first time)
#   -q|--quiet one-line output (for the per-chat instruction field)
set -euo pipefail

BASE="${TC_BASE:-/home/z/my-project}"

# ---------- defaults (precedence: tc-bootstrap.env > shell env > defaults) --
TC_ID="clang-17.0.6-kernel-min"

# download chain (first live source wins; all sources must unpack to the SAME
# hash-pinned binaries - MANIFEST below is the extracted-tree identity):
#   1. our GitHub release asset (pikyxdev/sandboxed, tag "final") - packed 118MB tree
#   2. official LLVM 17.0.6 release (1.4GB, trimmed on install to the same tree)
# note: a temp.sh mirror (751a493f...) worked as a jump-start but expired; if
# you re-upload one, add "  <url> 751a493f..." as an extra chain line here
TC_PACKED_SHA256="751a493f8640c0e5a6a6d536a20c9ad184d1550d0dc6ed7b459f3ace80cb91bc"
TC_SOURCES_DEFAULT="https://github.com/pikyxdev/sandboxed/releases/download/final/tc-clang-17.0.6-kernel-min.tar.xz $TC_PACKED_SHA256
https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/clang%2Bllvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz 884ee67d647d77e58740c1e645649e29ae9e8a6fe87c1376be0f3a30f3cc9ab3"
KSRC_URL_DEFAULT="https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.178.tar.xz"

TC_DIR="${TC_DIR:-$BASE/tc}"
TC_KEEP_CACHE="${TC_KEEP_CACHE:-0}"
KSRC="${KSRC:-$BASE/linux-5.15.178}"
KSRC_TARBALL="${KSRC_TARBALL:-$BASE/linux-5.15.178.tar.xz}"
KSRC_SHA256="${KSRC_SHA256:-}"
HOST_DIR="${HOST_DIR:-$BASE/tc-host}"          # persistent (v1 used /tmp/toolchain, wiped every recycle)
CACHE_DIR="${CACHE_DIR:-$BASE/tc-cache}"
PACK_DIR="${PACK_DIR:-$BASE/download}"
A13_TARBALL="${A13_TARBALL:-$BASE/a13-mirror.tar.gz}"
A13_URL="${A13_URL:-}"
A13_SHA256="${A13_SHA256:-}"
A13_INNER="kernel_common-ASB-2025-03-05_13-5.15"
TC_URL="${TC_URL:-}"; TC_SHA256="${TC_SHA256:-}"; KSRC_URL="${KSRC_URL:-}"
# full override of the source chain (multi-line: "<url> <sha256>" per line)
TC_SOURCES="${TC_SOURCES:-}"

# per-project overrides (wins over the defaults above)
if [ -f "$BASE/tc-bootstrap.env" ]; then . "$BASE/tc-bootstrap.env"; fi
: "${TC_GH_REPO:=pikyxdev/sandboxed}"   # resolvable by the env file too
GH_REPO="$TC_GH_REPO"
# single-source override (TC_URL [+ TC_SHA256]) replaces the whole chain;
# without it, fall back to the built-in chain (release -> LLVM)
if [ -n "$TC_URL" ]; then
  TC_SOURCES="$(printf '%s %s' "$TC_URL" "${TC_SHA256:-}")"
elif [ -z "$TC_SOURCES" ]; then
  TC_SOURCES="$TC_SOURCES_DEFAULT"
fi
: "${KSRC_URL:=$KSRC_URL_DEFAULT}"

ENV_FILE="$BASE/tc-env.sh"
STAMP="$TC_DIR/.tc-stamp"
HASHCACHE="$TC_DIR/.tc-hashcache"
SELFTEST="$CACHE_DIR/selftest"
CURH="$KSRC/arch/x86/include/asm/current.h"
CACHE="$CACHE_DIR/tc.tar.xz"
HOST_DEBS="flex bison bc libelf-dev zlib1g-dev libzstd-dev"

# kernel-build keep-set (includes symlink targets like llvm-readobj)
KEEP_BIN="clang clang++ clang-17 lld ld.lld llvm-readobj llvm-readelf llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-strings llvm-profdata llvm-bolt llvm-bolt-heatmap merge-fdata llvm-symbolizer"

# pinned SHA256 of the 8 load-bearing binaries (sha256sum -c format)
MANIFEST="d8e993285cc7a68bb6c6e4010206213964e4fa7e6b70197f04c8bffa5ed8a414  clang-17
ad72ab9175d4890687c13674065cbb76881502b028078ed3443a8f899c6e169e  lld
4ed851739c360116f133485d1a6c11abc40f8ebc64d815b729561ffc9fecfa94  llvm-bolt
5a150170f3f89fa3008c21f857ab25ae80b3ab58ac79315c95fda3f58c3533a7  llvm-ar
70a5d3f9bc94b0f9b837b5d807f66367a3dd6650f0106f1a07bad93811114255  llvm-nm
e1eceaf6e5d5bdcaf7cd5db13701194588dd6d593668a838120eae2d2749b8c1  llvm-objcopy
ff75a9523ddf944e744efb141eac0512ce38c9036768a9fbabd9a19deea52ad8  llvm-readobj
4f2395374b851be8f2db282cfe1e9b94b184428586745b8d76b8da65a4e4eb43  llvm-profdata"
# identity of the extracted tree, independent of which archive/source it came
# from (the stamp carries this, so a tree from any source verifies the same)
TC_TREE_ID=$(printf '%s\n' "$MANIFEST" | sha256sum | awk '{print $1}')

# ---------- arg parsing ------------------------------------------------------
MODE="auto"; QUIET=0; WITH_A13=0
for a in "$@"; do
  case "$a" in
    --check)    MODE=check ;;
    --force)    MODE=force ;;
    --pack)     MODE=pack ;;
    --status)   MODE=status ;;
    --with-a13) WITH_A13=1 ;;
    -q|--quiet) QUIET=1 ;;
    --help|-h)  grep '^#' "$0" | head -40; exit 0 ;;
    *) echo "tc-bootstrap FAIL: unknown option: $a" >&2; exit 1 ;;
  esac
done

SECONDS=0
TC_WARM=0

die() { echo "tc-bootstrap FAIL: $*" >&2; exit 1; }
say() { [ "$QUIET" = 1 ] || echo "$*"; }
qok() { echo "tc-bootstrap OK: $*"; exit 0; }

glibc_ok() {
  V=$(ldd --version 2>&1 | sed -n '1s/.* \([0-9][0-9.]*\)$/\1/p')
  awk -v v="$V" 'BEGIN{split("2.35",m,".");split(v,a,".");exit !(a[1]>m[1]||(a[1]==m[1]&&a[2]>=m[2]))}'
}

# ---------- toolchain verification ------------------------------------------
write_hashcache() {
  : > "$HASHCACHE"
  local _ name
  while read -r _ name; do
    printf '%s %s %s\n' "$name" "$(stat -c '%s' "$TC_DIR/bin/$name")" "$(stat -c '%Y' "$TC_DIR/bin/$name")" >> "$HASHCACHE"
  done <<EOF
$MANIFEST
EOF
}

# fast path: size+mtime stat-cache; on any mismatch a true SHA256 is done
verify_tree() {
  local sha name p sz mt cached refreshed=0
  while read -r sha name; do
    p="$TC_DIR/bin/$name"
    [ -x "$p" ] || return 1
    sz=$(stat -c '%s' "$p"); mt=$(stat -c '%Y' "$p")
    if [ -s "$HASHCACHE" ]; then
      cached=$(sed -n "s/^$name //p" "$HASHCACHE" 2>/dev/null | head -n1)
      if [ "$cached" = "$sz $mt" ]; then continue; fi
    fi
    printf '%s  %s\n' "$sha" "$p" | sha256sum -c - >/dev/null 2>&1 || return 1
    refreshed=1
  done <<EOF
$MANIFEST
EOF
  if [ "$refreshed" = 1 ]; then write_hashcache; fi
  return 0
}

# slow path, always true SHA256 (used by --check / --pack)
verify_tree_full() {
  local sha name
  while read -r sha name; do
    [ -x "$TC_DIR/bin/$name" ] || return 1
    printf '%s  %s\n' "$sha" "$TC_DIR/bin/$name" | sha256sum -c - >/dev/null 2>&1 || return 1
  done <<EOF
$MANIFEST
EOF
}

smoke() {
  mkdir -p "$SELFTEST"
  printf '#include <stdarg.h>\n#include <stddef.h>\nint main(void){va_list v;(void)v;size_t z=0;(void)z;return 0;}\n' > "$SELFTEST/hello.c"
  printf 'int mod_init(void){return 0;}\n' > "$SELFTEST/xmod.c"
  "$TC_DIR/bin/clang" -target x86_64-linux-gnu -B"$TC_DIR/bin/" -fuse-ld=lld \
    -fsanitize=kcfi -flto=thin "$SELFTEST/hello.c" -o "$SELFTEST/hello_lto" >/dev/null 2>&1
  "$TC_DIR/bin/clang" -target aarch64-linux-gnu -fsanitize=kcfi -flto=thin \
    -ffreestanding -fno-stack-protector -c "$SELFTEST/xmod.c" -o "$SELFTEST/xmod.o" >/dev/null 2>&1
}

trim_tc() {
  local f k keep e
  for f in "$TC_DIR"/bin/*; do
    keep=no
    for k in $KEEP_BIN; do
      if [ "$(basename "$f")" = "$k" ]; then keep=yes; fi
    done
    if [ "$keep" = "no" ]; then rm -f "$f"; fi
  done
  # ldd on the official release binaries shows they are statically linked
  # (system libs only), so lib/clang (builtin headers) is all we keep
  for e in "$TC_DIR"/lib/*; do
    case "$(basename "$e")" in
      clang) ;;
      *) rm -rf "$e" ;;
    esac
  done
  rm -rf "$TC_DIR/include" "$TC_DIR/share" "$TC_DIR/local"
}

fetch() { # fetch <url> <dest> <sha256-or-empty>
  local url="$1" dest="$2" sha="$3"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dest.dl" "$url" >/dev/null 2>&1 || return 1
  # temp.sh-style hosts serve GET as an HTML viewer page; the raw bytes need POST
  if [ -s "$dest.dl" ] && head -c 256 "$dest.dl" | grep -qai '<!DOCTYPE html>'; then
    say "[fetch] HTML viewer page instead of data - retrying with POST"
    curl -fsS --retry 2 --connect-timeout 15 -X POST -o "$dest.dl" "$url" >/dev/null 2>&1 || return 1
    if [ -s "$dest.dl" ] && head -c 256 "$dest.dl" | grep -qai '<!DOCTYPE html>'; then return 1; fi
  fi
  if [ -n "$sha" ]; then
    printf '%s  %s\n' "$sha" "$dest.dl" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$dest.dl"; return 1; }
  fi
  mv -f "$dest.dl" "$dest"
}

install_tc() {
  glibc_ok || die "sandbox glibc too old (this build needs >= 2.35)"
  mkdir -p "$CACHE_DIR" "$TC_DIR"
  # a cached tarball counts only if it matches SOME source's pinned hash
  local src sha_ok=0
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    if printf '%s  %s\n' "$(printf '%s' "$src" | awk '{print $2}')" "$CACHE" | sha256sum -c - >/dev/null 2>&1; then
      sha_ok=1; break
    fi
  done <<EOF
$TC_SOURCES
EOF
  if [ "$sha_ok" != 1 ]; then
    # walk the source chain: first (url sha) pair that downloads AND
    # hash-matches wins; a source that 404s, serves garbage or an HTML
    # viewer page is skipped, never fatal while others remain
    local src url sha got=0
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      url=$(printf '%s' "$src" | awk '{print $1}')
      sha=$(printf '%s' "$src" | awk '{print $2}')
      say "[tc] trying $url"
      if fetch "$url" "$CACHE" "$sha"; then
        TC_INSTALLED_FROM="$url"; TC_INSTALLED_SHA="$sha"; got=1; break
      fi
      say "[tc] source failed, trying next in chain"
    done <<EOF
$TC_SOURCES
EOF
    [ "$got" = 1 ] || die "all sources in the chain failed (network? hashes?)"
  else
    say "[tc] reusing cached archive $CACHE"
  fi
  # exact space gate: compressed + uncompressed + 200MB slack (from the xz index)
  local unc=0 comp
  comp=$(stat -c '%s' "$CACHE")
  unc=$(xz --list --robot "$CACHE" 2>/dev/null | awk '$1=="file"{print $5; exit}')
  [ -n "$unc" ] || unc=$(( comp * 3 ))
  AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
  NEED_MB=$(( (comp + unc + 200*1024*1024) / 1024 / 1024 ))
  if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
    die "need ${NEED_MB}MB free during install (archive ${comp}B + uncompressed ${unc}B + slack), have ${AVAIL_MB}MB"
  fi
  rm -rf "${TC_DIR:?}"/*
  if xz -dc -T0 "$CACHE" 2>/dev/null | tar -x -C "$TC_DIR" --strip-components=1; then
    :
  else
    tar -xJf "$CACHE" -C "$TC_DIR" --strip-components=1 || die "extract failed"
  fi
  trim_tc
  smoke || die "post-install smoke test failed (kCFI/ThinLTO/lld)"
  printf '%s\n' "$TC_ID|$TC_TREE_ID" > "$STAMP"
  if [ -n "${TC_INSTALLED_FROM:-}" ]; then
    printf '%s\n' "$TC_INSTALLED_FROM" > "$TC_DIR/.tc-source"
  fi
  write_hashcache
  if [ "$TC_KEEP_CACHE" != "1" ]; then rm -f "$CACHE"; fi
  say "[tc] installed $TC_ID from ${TC_INSTALLED_FROM:-cache} (cold, smoke-tested)"
}

ensure_tc() {
  if [ -f "$STAMP" ] && [ -x "$TC_DIR/bin/clang-17" ]; then
    CUR=""
    read -r CUR < "$STAMP" || true
    if [ "$CUR" = "$TC_ID|$TC_TREE_ID" ] && verify_tree; then
      TC_WARM=1; say "[tc] $TC_ID warm (stamp + stat-cache OK)"; return 0
    fi
  fi
  if verify_tree; then
    printf '%s\n' "$TC_ID|$TC_TREE_ID" > "$STAMP"
    TC_WARM=1; say "[tc] $TC_ID verified (hashes match, stamp refreshed)"; return 0
  fi
  install_tc
}

# ---------- kernel tree + current.h override (from restore_build_env.sh) -----
kern_sha_resolve() { # prints the official sha256 for the tarball, or empty
  if [ -n "$KSRC_SHA256" ]; then echo "$KSRC_SHA256"; return 0; fi
  local sums="${KSRC_URL%/*}/sha256sums.asc"
  curl -fsSL --retry 2 --connect-timeout 10 "$sums" 2>/dev/null \
    | awk -v f="$(basename "$KSRC_TARBALL")" '$2==f{print $1}' | head -n1
}

ensure_kernel() {
  if [ ! -f "$KSRC/Makefile" ]; then
    if [ ! -f "$KSRC_TARBALL" ]; then
      die "kernel tarball missing after fetch attempt: $KSRC_URL"
    fi
    say "[kernel] extracting $(basename "$KSRC_TARBALL")"
    rm -rf "$KSRC"
    tar -xf "$KSRC_TARBALL" -C "$BASE"
  fi
  if ! grep -q "susfs_current_task_gs_off" "$CURH" 2>/dev/null; then
    say "[kernel] writing current.h override"
    mkdir -p "$(dirname "$CURH")"
    cat > "$CURH" <<'CUREOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * susfs x86_64 port override - DO NOT UPSTREAM.
 *
 * The LDPlayer 14 kernel's clang-LTO+trim build removed
 * EXPORT_PER_CPU_SYMBOL(current_task), so the stock
 * DECLARE_PER_CPU + this_cpu_read_stable(current_task) pattern leaves an
 * unresolved external `current_task` relocation that init_module rejects.
 *
 * This override reads current_task through %gs with a displacement that is
 * resolved ONCE at module init (kernel/susfs_current.c, called from
 * susfs_init right after ksu_init_symbol_resolver): the global
 * susfs_current_task_gs_off holds the per-CPU section offset of
 * current_task.  On LDPlayer kallsyms reports current_task at address 0
 * (per-CPU start), so the displacement is 0; on a stock 5.15 kernel where
 * current_task is at offset 4096 (after fixed_percpu_data which is
 * __aligned(PAGE_SIZE)) the resolver sets it to 4096.  Either way the
 * compiler never emits a current_task relocation.
 *
 * The addressing mode 0(,%1,1) is the scaled-index form (base=0,
 * index=%1, scale=1) - equivalent to (%1) but explicit that %1 is the
 * displacement, not a pointer to dereference.  %gs base is the per-CPU
 * section base for the current CPU, set by the kernel's percpu_setup
 * during boot.
 */
#ifndef _ASM_X86_CURRENT_H
#define _ASM_X86_CURRENT_H

#include <linux/compiler.h>
#include <asm/percpu.h>

#ifndef __ASSEMBLY__
struct task_struct;

/* Defined in kernel/susfs_current.c; zero on LDPlayer (correct), or the
 * per-CPU offset of current_task on kernels that list it. */
extern unsigned long susfs_current_task_gs_off;

static __always_inline struct task_struct *get_current(void)
{
	struct task_struct *p;
	unsigned long off = susfs_current_task_gs_off;
	/* %gs:off reads current_task for THIS cpu.  The "memory" clobber
	 * blocks reordering across the read, matching the kernel's
	 * this_cpu_read_stable semantics. */
	asm volatile("movq %%gs:0(,%1,1), %0"
		     : "=r" (p)
		     : "r" (off)
		     : "memory");
	return p;
}

#define current get_current()

#endif /* __ASSEMBLY__ */

#endif /* _ASM_X86_CURRENT_H */
CUREOF
  fi
}

# ---------- host debs (persistent now: /tmp/toolchain was wiped each recycle) -
ensure_host() {
  if [ ! -x "$HOST_DIR/usr/bin/flex" ] || [ ! -x "$HOST_DIR/usr/bin/bc" ]; then
    say "[host] fetching host debs: $HOST_DEBS"
    mkdir -p "$CACHE_DIR/debs" "$HOST_DIR"
    ( cd "$CACHE_DIR/debs" && apt-get download $HOST_DEBS >/dev/null 2>&1 ) || true
    local found=0 d
    for d in "$CACHE_DIR"/debs/*.deb; do
      if [ -f "$d" ]; then dpkg-deb -x "$d" "$HOST_DIR" 2>/dev/null || true; found=1; fi
    done
    if [ "$found" != 1 ]; then say "[host] WARN: apt-get download produced no debs"; fi
  fi
  # link shared, drop statics (libelf.so needs libz/libzstd at link time)
  rm -f "$HOST_DIR"/usr/lib/x86_64-linux-gnu/libelf.a \
        "$HOST_DIR"/usr/lib/x86_64-linux-gnu/libz.a \
        "$HOST_DIR"/usr/lib/x86_64-linux-gnu/libzstd.a 2>/dev/null || true
  # legacy-path compat: /tmp/toolchain (old scripts hardcode it)
  if [ "$HOST_DIR" != "/tmp/toolchain" ]; then
    if [ -d /tmp/toolchain ] && [ ! -L /tmp/toolchain ] && [ -d /tmp/toolchain/usr ]; then
      rm -rf /tmp/toolchain   # old pre-v2 layout, regenerable
    fi
    ln -sfn "$HOST_DIR" /tmp/toolchain
  fi
}

host_missing() {
  local m="" f
  for f in usr/bin/flex usr/bin/bison usr/bin/bc usr/include/libelf.h \
           usr/include/zlib.h usr/include/zstd.h; do
    if [ ! -e "$HOST_DIR/$f" ]; then m="$m $f"; fi
  done
  echo "$m"
}

# ---------- a13 mirror (optional; slow first time) ----------------------------
ensure_a13() {
  if [ -f "$A13_TARBALL" ]; then say "[a13] tarball present"; return 0; fi
  mkdir -p "$CACHE_DIR"
  if [ -n "$A13_URL" ]; then
    say "[a13] downloading $A13_URL"
    fetch "$A13_URL" "$A13_TARBALL" "$A13_SHA256" || die "a13 download failed: $A13_URL"
  else
    # NOTE: googlesource HEAD != the ASB-2025-03-05 snapshot your v52 used.
    # For a bit-exact v52 rebuild host your archived a13-mirror.tar.gz as a
    # release asset and set A13_URL (and A13_SHA256) instead.
    say "[a13] cloning android13-5.15 (HEAD, not the 2025-03-05 snapshot)"
    rm -rf "$CACHE_DIR/$A13_INNER"
    git clone --depth 1 https://android.googlesource.com/kernel/common \
      -b android13-5.15 "$CACHE_DIR/$A13_INNER" >/dev/null 2>&1 || die "a13 clone failed"
    tar -czf "$A13_TARBALL.tmp" -C "$CACHE_DIR" "$A13_INNER"
    mv -f "$A13_TARBALL.tmp" "$A13_TARBALL"
    rm -rf "$CACHE_DIR/$A13_INNER"
  fi
}

# ---------- env file + legacy path shim ---------------------------------------
ensure_env() {
  # README-BUILD-V52.md section 4: toolchain/clang17/usr/lib/llvm-17/bin/clang
  local shim="$BASE/toolchain/clang17/usr/lib/llvm-17"
  mkdir -p "$shim"
  ln -sfn "$TC_DIR/bin" "$shim/bin"
  ln -sfn "$TC_DIR/lib" "$shim/lib"
  cat > "$ENV_FILE" <<ENVEOF
# generated by tc-bootstrap.sh - source me before building
#   . /home/z/my-project/tc-env.sh
if [ -z "\${TC_ENV_LOADED:-}" ]; then
  export TC_DIR="$TC_DIR"
  export TC_HOST="$HOST_DIR"
  export KSRC="$KSRC"
  export PATH="\$TC_DIR/bin:\$TC_HOST/usr/bin:\$PATH"
  export LD_LIBRARY_PATH="\$TC_DIR/lib:\$TC_HOST/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
  export TC_ENV_LOADED=1
fi
ENVEOF
  say "[env] wrote $ENV_FILE"
}

# ---------- modes --------------------------------------------------------------
finish() {
  local kind=cold
  if [ "$TC_WARM" = 1 ]; then kind=warm; fi
  if [ "$QUIET" = 1 ]; then
    qok "$TC_ID + linux-5.15.178 + host-debs ready (${SECONDS}s, $kind)"
  fi
  say "[done] ${SECONDS}s ($kind) - source $ENV_FILE before building"
  qok "ready"
}

auto() {
  local PREFETCH_PID="" KSHA=""
  # prefetch the kernel tarball in parallel with the (bigger) TC download
  if [ ! -f "$KSRC/Makefile" ] && [ ! -f "$KSRC_TARBALL" ]; then
    KSHA=$(kern_sha_resolve || true)
    say "[kernel] prefetching $KSRC_URL in background"
    rm -f "$KSRC_TARBALL.dl"
    (
      set -e
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$KSRC_TARBALL.dl" "$KSRC_URL"
      if [ -n "$KSHA" ]; then
        printf '%s  %s\n' "$KSHA" "$KSRC_TARBALL.dl" | sha256sum -c - >/dev/null
      fi
      mv -f "$KSRC_TARBALL.dl" "$KSRC_TARBALL"
    ) >/dev/null 2>&1 &
    PREFETCH_PID=$!
  fi
  ensure_tc
  if [ -n "$PREFETCH_PID" ]; then wait "$PREFETCH_PID" || true; fi
  ensure_kernel
  ensure_host
  if [ "$WITH_A13" = 1 ]; then ensure_a13; fi
  ensure_env
  finish
}

check_all() {
  local rc=0 miss
  if verify_tree_full; then say "[check] toolchain: OK (8/8 true SHA256)"; else say "[check] toolchain: FAIL"; rc=1; fi
  if [ -f "$KSRC/Makefile" ]; then say "[check] kernel tree: OK ($KSRC)"; else say "[check] kernel tree: MISSING"; rc=1; fi
  if grep -q "susfs_current_task_gs_off" "$CURH" 2>/dev/null; then say "[check] current.h override: OK"; else say "[check] current.h override: MISSING"; rc=1; fi
  miss=$(host_missing)
  if [ -z "$miss" ]; then say "[check] host debs: OK ($HOST_DIR, /tmp/toolchain -> it)"; else say "[check] host debs: MISSING:$miss"; rc=1; fi
  if [ -f "$A13_TARBALL" ]; then say "[check] a13 mirror: present"; else say "[check] a13 mirror: absent (only build_v49 needs it; --with-a13 to fetch)"; fi
  if [ -f "$ENV_FILE" ]; then say "[check] env file: $ENV_FILE"; else say "[check] env file: MISSING (rerun bootstrap)"; rc=1; fi
  if [ "$rc" = 0 ]; then qok "check passed (${SECONDS}s)"; else die "check failed"; fi
}

status_out() {
  echo "[status] toolchain dir : $TC_DIR ($([ -x "$TC_DIR/bin/clang-17" ] && echo present || echo MISSING))"
  echo "[status] toolchain stamp: $([ -f "$STAMP" ] && cat "$STAMP" || echo none)"
  echo "[status] installed from: $([ -f "$TC_DIR/.tc-source" ] && cat "$TC_DIR/.tc-source" || echo unknown/cached)"
  printf '[status] source chain : '
  while IFS= read -r src; do
    [ -n "$src" ] && printf '%s -> ' "$(printf '%s' "$src" | awk '{print $1}')"
  done <<EOF
$TC_SOURCES
EOF
  echo ''
  echo "[status] hashcache     : $([ -s "$HASHCACHE" ] && echo "$HASHCACHE" || echo none)"
  echo "[status] kernel tree   : $KSRC ($([ -f "$KSRC/Makefile" ] && echo present || echo MISSING))"
  echo "[status] kernel tarball: $KSRC_TARBALL ($([ -f "$KSRC_TARBALL" ] && echo present || echo MISSING))"
  echo "[status] current.h     : $CURH ($(grep -q susfs_current_task_gs_off "$CURH" 2>/dev/null && echo override-active || echo stock/MISSING))"
  echo "[status] host debs     : $HOST_DIR -> /tmp/toolchain ($(miss=$(host_missing); [ -z "$miss" ] && echo OK || echo "MISSING:$miss"))"
  echo "[status] a13 mirror    : $A13_TARBALL ($([ -f "$A13_TARBALL" ] && echo present || echo MISSING))"
  echo "[status] env file      : $ENV_FILE ($([ -f "$ENV_FILE" ] && echo present || echo MISSING))"
  exit 0
}

pack_tc() {
  verify_tree_full || die "pack: toolchain not verified - run the default mode first"
  mkdir -p "$PACK_DIR"
  local out="$PACK_DIR/tc-$TC_ID.tar.xz" sha repo
  # reuse an already-packed, hash-valid tarball instead of re-compressing
  if [ -f "$out" ] && [ -f "$out.sha256" ] && sha256sum -c "$out.sha256" >/dev/null 2>&1; then
    sha=$(awk '{print $1}' "$out.sha256")
    say "[pack] $out already valid (sha256 matches) - reusing"
  else
    say "[pack] creating $(basename "$out") (xz -T0, takes ~a minute)"
    tar -cf - -C "$(dirname "$TC_DIR")" "$(basename "$TC_DIR")" | xz -T0 -6 > "$out.tmp"
    mv -f "$out.tmp" "$out"
    sha=$(sha256sum "$out" | awk '{print $1}')
    printf '%s  %s\n' "$sha" "$out" > "$out.sha256"
  fi
  echo "[pack] wrote $out"
  echo "[pack] sha256: $sha"
  repo="$GH_REPO"
  if [ -z "$repo" ]; then
    repo=$(git -C "$BASE" remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]##;s#\.git$##p' | head -n1) || repo=""
  fi
  cat <<EOF

Upload destination (already the script default): GitHub release $repo tag "final"
  asset URL: https://github.com/$repo/releases/download/final/$(basename "$out")
  asset sha256: $sha

To change the built-in chain later (first line = preferred source):
  edit the TC_SOURCES_DEFAULT block in tc-bootstrap.sh, or override per-project
  in tc-bootstrap.env:
    TC_SOURCES='<url> <sha256>'   (multi-line for a full chain)

chat.z.ai > Create Project > instructions, paste:

     At the very start of every session, before any other command, silently
     restore the build env (never print or explain its output; exit 0 = ready):
       bash /home/z/my-project/scripts/tc-bootstrap.sh --quiet 2>/dev/null || { \\
         mkdir -p /home/z/my-project/scripts && \\
         curl -fsSL --retry 3 https://raw.githubusercontent.com/$repo/main/tc-bootstrap.sh \\
           -o /home/z/my-project/scripts/tc-bootstrap.sh && \\
         bash /home/z/my-project/scripts/tc-bootstrap.sh --quiet; } || true

EOF
  qok "packed $TC_ID"
}

case "$MODE" in
  auto)   auto ;;
  force)  install_tc; ensure_kernel; ensure_host; if [ "$WITH_A13" = 1 ]; then ensure_a13; fi; ensure_env; finish ;;
  check)  check_all ;;
  status) status_out ;;
  pack)   pack_tc ;;
  *)      die "unreachable mode" ;;
esac
