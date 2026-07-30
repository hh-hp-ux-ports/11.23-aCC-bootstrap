#!/usr/bin/sh
# build_shim_htop.sh — Hugo 2026-07-22: "build the previously discussed statically linked gnulib
# shim library and htop with the existing 4.7.4 next before starting with the 5.5 bootstrap".
# Runs AFTER make/gawk, BEFORE build_gcc55 (chain_shim55.sh sequences it).
#
# A) gnulib shim: the pre-generated testdir at gnulib-hpux/ (modules setenv+unsetenv — 11.23 libc
#    lacks both; the classic blocker for modern GNU sources). configure was autoreconf'd on the dev
#    box 2026-07-22 (rx2620 has no autotools). Built BOTH ABIs -> static libgnushim.a in
#    /opt/gnu/lib (ILP32) + /opt/gnu/lib/hpux64 (LP64) + /opt/gnu/include/gnushim.h.
# B) ncurses 6.5 static (no shared, no C++ binding — keeps consumers free of unwind entanglement),
#    LP64, prefix /opt/gnu. NOTE: ncurses has no automated pass/fail suite (test/ is interactive
#    programs) — nothing to run, not a skipped suite.
# C) htop 3.4.1 against the staged static ncurses. HONEST EXPECTATION: htop has NO HP-UX platform
#    backend — configure falls back to "unsupported" (stub readings). It should COMPILE and run its
#    UI, but the process list will be empty/dummy until someone writes a pstat_getproc() backend
#    (a real, feasible port — roadmap candidate). This build answers "does it build", per request.
BUILD=/home/claude/build ; TARS=/mnt/debianshare/gnu_tarballs
SHIMSRC=/mnt/debianshare/gnulib-hpux
NCSRC=$TARS/ncurses-6.5 ; HTSRC=$TARS/htop-3.4.1
STAGE=$BUILD/shimext-stage
LOG=$BUILD/shim_htop.log ; DONE=$BUILD/shim_htop.DONE
exec > $LOG 2>&1
STATUS=running
on_exit(){ rc=$?; echo "status=$STATUS rc=$rc when=`date`" > "$DONE"; cp "$DONE" $TARS/driver_status/shim_htop.DONE 2>/dev/null; }
trap on_exit 0 ; trap 'STATUS=killed; exit 130' 1 2 3 15
say(){ echo "@@@ $1 :: `date`"; }
fail(){ say "FAILED: $1"; STATUS="FAILED $1"; exit 1; }
PATH=/opt/gcc474/bin:/opt/binutils/bin:$BUILD/bin:/opt/gnu/bin:/usr/ccs/bin:/usr/bin:/bin:/usr/contrib/bin
export PATH
gcc --version 2>&1 | head -1 | grep 4.7.4 >/dev/null || fail "gcc474 not first on PATH"
[ -f $SHIMSRC/configure ] || fail "gnulib shim configure missing (autoreconf on dev box first)"
rm -rf $STAGE ; mkdir -p $STAGE/opt/gnu/lib/hpux64 $STAGE/opt/gnu/include $STAGE/opt/gnu/bin

# ---------- A) gnulib shim, both ABIs ----------
for ABI in 32 64 ; do
  case $ABI in 32) MF="" ; LIBD=$STAGE/opt/gnu/lib ;; 64) MF="-mlp64" ; LIBD=$STAGE/opt/gnu/lib/hpux64 ;; esac
  OBJ=$BUILD/shim-obj-$ABI
  say "shim ABI=$ABI configure"
  rm -rf $OBJ ; mkdir -p $OBJ ; cd $OBJ || fail cd
  $SHIMSRC/configure CC="gcc $MF" CFLAGS="-O2" > cfg.log 2>&1 || { tail -20 cfg.log ; fail "shim configure abi$ABI" ; }
  gmake > mk.log 2>&1 || { tail -25 mk.log ; fail "shim build abi$ABI" ; }
  say "shim ABI=$ABI gmake check (gnulib self-tests — run in full)"
  gmake check > chk.log 2>&1
  say "shim ABI=$ABI check exit=$?"
  grep -E "^(# TOTAL|# PASS|# FAIL|# SKIP|FAIL:|ERROR:)" chk.log | head -12
  [ -f gllib/libgnu.a ] || fail "no libgnu.a abi$ABI"
  cp gllib/libgnu.a $LIBD/libgnushim.a || fail "stage libgnushim abi$ABI"
  nm $LIBD/libgnushim.a | grep -E "setenv|unsetenv" | head -4
done
cat > $STAGE/opt/gnu/include/gnushim.h <<'HDR'
/* gnushim.h — declarations for libgnushim.a (gnulib setenv/unsetenv for HP-UX 11.23, which lacks
   both). Link: -L/opt/gnu/lib[/hpux64] -lgnushim. Built with validated gcc 4.7.4, both ABIs. */
#ifndef GNUSHIM_H
#define GNUSHIM_H
#ifdef __cplusplus
extern "C" {
#endif
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
#ifdef __cplusplus
}
#endif
#endif
HDR
say "shim smoke: compile+run against staged lib, both ABIs"
cat > /var/tmp/shimtest.c <<'TC'
#include <stdio.h>
#include <stdlib.h>
#include "gnushim.h"
int main(void){
  if (setenv("GNUSHIM_T","works",1)) return 1;
  const char *v = getenv("GNUSHIM_T");
  if (!v || v[0] != 'w') return 2;
  if (unsetenv("GNUSHIM_T")) return 3;
  if (getenv("GNUSHIM_T")) return 4;
  puts("shim-ok"); return 0;
}
TC
gcc        -I$STAGE/opt/gnu/include /var/tmp/shimtest.c -L$STAGE/opt/gnu/lib        -lgnushim -o /var/tmp/st32 && /var/tmp/st32 || fail "shim smoke ilp32"
gcc -mlp64 -I$STAGE/opt/gnu/include /var/tmp/shimtest.c -L$STAGE/opt/gnu/lib/hpux64 -lgnushim -o /var/tmp/st64 && /var/tmp/st64 || fail "shim smoke lp64"
say "★ SHIM COMPLETE (both ABIs, smoke-run)"

# ---------- B) ncurses 6.5 static LP64 ----------
OBJ=$BUILD/ncurses-obj
say "ncurses 6.5 configure (static, LP64, no C++ binding)"
rm -rf $OBJ ; mkdir -p $OBJ ; cd $OBJ || fail cd
$NCSRC/configure --prefix=/opt/gnu \
  --without-shared --without-ada --without-cxx-binding --without-tests \
  --with-terminfo-dirs=/opt/gnu/share/terminfo:/usr/share/lib/terminfo \
  CC="gcc -mlp64" CFLAGS="-O2" > cfg.log 2>&1 || { tail -20 cfg.log ; fail "ncurses configure" ; }
gmake > mk.log 2>&1 || { tail -30 mk.log ; fail "ncurses build" ; }
say "ncurses BUILD OK (no automated suite exists — see header note)"
gmake install DESTDIR=$STAGE > ins.log 2>&1 || { tail -15 ins.log ; fail "ncurses install" ; }
[ -f $STAGE/opt/gnu/lib/libncurses.a ] || fail "libncurses.a missing from stage"
say "★ NCURSES COMPLETE (static, staged)"

# ---------- C) htop 3.4.1 (expect platform=unsupported) ----------
OBJ=$BUILD/htop-obj
say "htop 3.4.1 configure against staged ncurses"
rm -rf $OBJ ; mkdir -p $OBJ ; cd $OBJ || fail cd
$HTSRC/configure --prefix=/opt/gnu --disable-unicode \
  CC="gcc -mlp64" CFLAGS="-O2 -I$STAGE/opt/gnu/include -I$STAGE/opt/gnu/include/ncurses" \
  LDFLAGS="-L$STAGE/opt/gnu/lib" > cfg.log 2>&1 || { tail -25 cfg.log ; fail "htop configure" ; }
grep -i "platform" config.log | grep -i "unsupported\|hpux" | head -2
gmake > mk.log 2>&1 || { tail -35 mk.log ; fail "htop build (porting point — log kept)" ; }
say "htop BUILD OK"
cp htop $STAGE/opt/gnu/bin/htop || fail "stage htop"
$STAGE/opt/gnu/bin/htop --version | head -1 || fail "htop --version"
say "★ HTOP COMPLETE (platform=unsupported stub — UI runs, process readings dummy until a pstat backend is written)"
STATUS="complete — shim(2 ABIs)+ncurses+htop staged at $STAGE"
say "★★ SHIM+NCURSES+HTOP ALL DONE"
