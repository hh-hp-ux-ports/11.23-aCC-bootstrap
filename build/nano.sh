#!/usr/bin/sh
# build_nano.sh — GNU nano for the GNUtools depot (Hugo 2026-07-27).
#
# LADDER (latest first, per the standing rule; fall back only on real incompatibility):
#   9.1 (newest) -> 8.7.1 -> 7.2 -> 5.9 -> 4.9.3
# nano 9.1 bundles a LARGE modern gnulib (329 files in lib/), which is exactly the thing the
# recorded BIG FINDING says breaks on 11.23 — but that finding was measured with gcc 4.6.1, and
# grep 3.12 (equally gnulib-heavy) built clean with the validated 4.7.4 on 2026-07-26. So latest
# first is a fair bet; the ladder is there for when it isn't.
#
# CURSES: nano needs a wide-character curses. HP's /usr/lib/libcurses is NOT enough (no wget_wch).
# ncurses 6.5 wide (libncursesw.a, ELF-64/IA64, headers in /opt/gnu/include/ncursesw) is already
# installed as GNUtools.ncurses 1.2.2, and its terminfo db is at /opt/gnu/share/terminfo.
# nano's configure tries pkg-config FIRST (PKG_CHECK_MODULES([NCURSESW],[ncursesw])); there is no
# ncursesw.pc on this box, but PKG_CHECK_MODULES honours pre-set *_CFLAGS/*_LIBS and skips the
# pkg-config call entirely — so set those rather than relying on the AC_CHECK_LIB fallback.
#
# NO TEST SUITE: nano ships no tests/ dir and no TESTS in Makefile.am, so `make check` is vacuous.
# Do NOT copy grep's "0 passes = reject" rule here — it would reject every rung. Gate on a
# functional acceptance run instead (binary is ELF-64, --version and --help work).
# ⚠️ PATCH REQUIRED, and the ladder does NOT route around it. Every nano from 4.9.3 to 9.1 reads
# fileinfo.st_mtim.tv_sec/.tv_nsec, and HP-UX 11.23 has NO nanosecond stat timestamps at all:
# sys/_stat_body.h defines `time_t st_atime; int st_spare1; time_t st_mtime; int st_spare2;` with no
# timespec member, so nano's own __APPLE__ hook (#define st_mtim st_mtimespec) has nothing to alias
# to. Descending the ladder is useless — all five versions fail identically on
#   error: 'struct stat' has no member named 'st_mtim'
# FIX (applied to the nano-9.1 tree on the share, recorded as
# nano-9.1-hpux1123-stat-time.patch): use the gnulib stat-time module nano already BUNDLES —
# get_stat_mtime()/get_stat_atime() return a struct timespec on every platform, with or without
# st_mtim. No type punning, and correct everywhere, so it is not an HP-UX-only hack.
NAME=nano
VERSIONS="9.1"   # only 9.1 is patched; the ladder cannot route around either defect
SRCROOT=/mnt/debianshare/gnu_tarballs
PREFIX=/opt/gnu                     # GNUtools lives here
ABI="-mlp64"                        # LP64 per ABI policy; libncursesw.a is ELF-64, must match
NCDIR=/opt/gnu

B=/home/claude/build
STAGE=$B/stage-$NAME
LOG=$B/${NAME}_build.log ; DONE=$B/${NAME}.DONE
TARS=/mnt/debianshare/gnu_tarballs
exec > $LOG 2>&1
STATUS=running ; BUILT=""
on_exit(){ rc=$?; echo "status=$STATUS rc=$rc built=$BUILT when=`date`" > "$DONE"; cp "$DONE" $TARS/driver_status/nano.DONE 2>/dev/null; }
trap on_exit 0 ; trap 'STATUS=killed; exit 130' 1 2 3 15
say(){ echo "@@@ $1 :: `date`"; }

# INSTALLED toolchain: /opt/gnu/gcc474 is the aCC-rooted validated 4.7.4 that is now the box
# default, and its specs auto-link -lunwind. GNU make is on /opt/gnu as BOTH make and gmake (the
# autotools depfiles bootstrap invokes bare `make`; HP make cannot do it).
PATH=/opt/gnu/gcc474/bin:/opt/gnu/binutils2461/bin:/opt/gnu/bin:/usr/ccs/bin:/usr/bin:/bin
export PATH
rm -rf $STAGE ; mkdir -p $STAGE

say "START nano build — compiler: `gcc --version | head -1`, make: `make --version | head -1`"
say "ncurses: `grep -m1 NCURSES_VERSION\\  $NCDIR/include/ncursesw/curses.h 2>/dev/null`"

try_build(){    # $1=version  $2=extra LDFLAGS  $3=label
  V=$1 ; XLD=$2 ; LBL=$3
  SRC=$SRCROOT/$NAME-$V
  [ -d "$SRC" ] || { say "no source $SRC — skipping"; return 1; }
  # cd OUT of the build dir before removing it: on a failed attempt the shell's cwd is still inside
  # it and HP-UX refuses with "Device busy", leaving stale configure output for the next rung.
  BLD=$B/bld-$NAME ; cd $B || return 1 ; rm -rf $BLD ; mkdir -p $BLD ; cd $BLD || return 1
  say "----- nano-$V configure ($LBL) -----"
  # -O2 not -O3: ia64 -O3 is cursed across gcc versions on this box (proven repeatedly).
  # --disable-nls: the box's gettext is 0.10.39.13 (1999-era) and nano's po/ machinery expects far
  #   newer; NLS buys nothing here and drags in libintl problems.
  # --disable-libmagic: no libmagic on the box (optional file-type detection only).
  # --disable-dependency-tracking: one-shot package build; also dodges the depfiles bootstrap trap.
  # ⚠️ BOTH include dirs are required, measured 2026-07-27. ncurses is installed with its headers
  # in a SUBDIRECTORY (/opt/gnu/include/ncursesw/curses.h), and that curses.h line 90 does
  #     #include <ncursesw/ncurses_dll.h>
  # i.e. it resolves its own siblings relative to the PARENT include dir. With only
  # -I/opt/gnu/include/ncursesw you get: "fatal error: ncursesw/ncurses_dll.h: No such file or
  # directory" on the first source file, long after configure has happily reported ncursesw found.
  CC="gcc $ABI" CFLAGS="-O2" \
  CPPFLAGS="-I$NCDIR/include/ncursesw -I$NCDIR/include" \
  LDFLAGS="-L$NCDIR/lib -lunwind -lm $XLD" \
  NCURSESW_CFLAGS="-I$NCDIR/include/ncursesw -I$NCDIR/include" \
  NCURSESW_LIBS="-L$NCDIR/lib -lncursesw" \
    $SRC/configure --prefix=$PREFIX --disable-dependency-tracking --disable-nls --disable-libmagic \
    > cfg.log 2>&1 || { say "nano-$V CONFIGURE failed ($LBL)"; tail -20 cfg.log; return 1; }
  say "nano-$V curses decision: `grep -iE 'curses' config.log | grep -iE 'lib_name|CURSES_LIB=' | head -3`"
  say "nano-$V make ($LBL)"
  make > mk.log 2>&1 || {
    say "nano-$V BUILD failed ($LBL)"
    grep -i "implicit declaration of function .strlen" mk.log > /dev/null 2>&1 && \
      say "  ^^ THE modern-gnulib header-replacement signature — this version is not viable on 11.23"
    grep -i "Unsatisfied symbol" mk.log | head -8
    tail -20 mk.log
    return 1 ; }
  # vacuous by design (no tests) — run it anyway so a future version that DOES ship tests is caught
  cp mk.log $B/mk-$NAME-$V-$LBL.log 2>/dev/null
  cp config.h $B/configh-$NAME-$V-$LBL.log 2>/dev/null
  say "nano-$V make check (nano ships no tests; informational only)"
  make check > chk.log 2>&1 ; say "  check rc=$? PASS=`grep -c '^PASS:' chk.log 2>/dev/null` FAIL=`grep -c '^FAIL:' chk.log 2>/dev/null`"

  # ---- ACCEPTANCE: this replaces the test-count gate ----
  BIN=src/nano
  [ -x "$BIN" ] || { say "nano-$V NO BINARY at $BIN — reject"; return 1; }
  say "nano-$V file: `file $BIN`"
  file $BIN 2>/dev/null | grep -i "ELF-64" > /dev/null || { say "nano-$V binary is not ELF-64 — reject"; return 1; }
  ./$BIN --version > ver.log 2>&1 || { say "nano-$V --version FAILED — reject"; tail -5 ver.log;
      cp $BIN $B/nano-failed-$V 2>/dev/null; say "  failed binary kept at $B/nano-failed-$V for gdb"; return 1; }
  say "nano-$V --version: `head -1 ver.log`"
  ./$BIN --help > help.log 2>&1 || { say "nano-$V --help FAILED — reject"; tail -5 help.log; return 1; }
  say "nano-$V --help lines: `wc -l < help.log`"

  say "nano-$V install DESTDIR=$STAGE"
  make install DESTDIR=$STAGE > ins.log 2>&1 || { say "install failed"; tail -10 ins.log; return 1; }
  BUILT="nano-$V ($LBL)"
  return 0
}

# NO -lgnushim RETRY HERE, unlike build_grep.sh — nano needs no shim, and getting it wrong is
# expensive. libgnushim is MULTILIB: /opt/gnu/lib/libgnushim.a is ELF-32 and the LP64 copy is at
# /opt/gnu/lib/hpux64/libgnushim.a. Linking the ILP32 one into an -mlp64 build makes configure fail
# its trivial conftest with the thoroughly misleading "C compiler cannot create executables" (cost
# a wrong diagnosis 2026-07-27 — the compiler links fine by hand). If a future rung really does need
# the shim, it is `-L/opt/gnu/lib/hpux64 -lgnushim`.
for V in $VERSIONS ; do
  if try_build $V "" "plain" ; then break ; fi
  say "===== nano-$V rejected — descending the ladder ====="
  BUILT=""
done

[ -z "$BUILT" ] && { STATUS="FAILED — no nano version built on this box"; say "ALL RUNGS FAILED"; exit 1; }
say "★ BUILT: $BUILT — staged at $STAGE$PREFIX"
ls -la $STAGE$PREFIX/bin/nano $STAGE$PREFIX/bin/rnano 2>/dev/null
say "staged tree:"
( cd $STAGE$PREFIX && find . -type f | sed 's|^\./|  |' | head -30 )

say "===== linkage (must be system libs only — ncursesw is static) ====="
chatr $STAGE$PREFIX/bin/nano 2>/dev/null | grep -iE "shared library list|dynamic|:" | head -20
STATUS="complete — $BUILT"
say "DONE"
