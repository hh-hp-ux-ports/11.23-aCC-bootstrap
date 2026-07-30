#!/usr/bin/sh
# build_grep.sh — GNU grep for GNUtools 1.3 (Hugo's top priority: HP grep has no -A/-B/-r/-o and no
# \| BRE alternation, which has produced WRONG ANALYSIS on this project more than once).
#
# LADDER (Hugo: latest first, fall back only on real incompatibility):
#   3.12 (2025, newest) -> 3.11 -> 3.7 -> 3.6 -> 3.4 (2020)
# WHY a ladder is needed here specifically: the recorded BIG FINDING is that MODERN gnulib's
# header-replacement wrapper is broken on 11.23 (the tell is `implicit declaration of strlen`), and
# that is an OS+gnulib problem largely INDEPENDENT of the compiler — so a validated gcc 4.7.4 does
# not guarantee 3.12 builds. Versions predating that aggressive header replacement build clean.
#
# libgnushim: 11.23 lacks setenv/unsetenv etc. grep BUNDLES gnulib so it usually needs nothing, but
# if a link fails on unsatisfied symbols we retry the SAME version with -lgnushim before demoting it
# — per the standing rule, never hand-roll compat, use the shim.
NAME=grep
VERSIONS="3.12 3.11 3.7 3.6 3.4"
SRCROOT=/mnt/debianshare/gnu_tarballs
PREFIX=/opt/gnu                     # GNUtools lives here
ABI="-mlp64"                        # LP64 per ABI policy
# MAXFAIL counts DISTINCT failing tests. Automake prints each failure TWICE in different formats
# ("FAIL: name" and "FAIL name (exit status: 1)"), so a naive `grep -c "^FAIL"` double-counts and
# demoted grep 3.12 on a bogus "6 failures" when it really had 2 (2026-07-26). Count `^FAIL:` only,
# deduped. 5 distinct is broad enough to catch a genuinely broken port without rejecting the
# handful of environment-specific tests every GNU suite fails on a 2004 Unix.
MAXFAIL=5

B=/home/claude/build
STAGE=$B/stage-$NAME
LOG=$B/${NAME}_build.log ; DONE=$B/${NAME}.DONE
TARS=/mnt/debianshare/gnu_tarballs
exec > $LOG 2>&1
STATUS=running ; BUILT=""
on_exit(){ rc=$?; echo "status=$STATUS rc=$rc built=$BUILT when=`date`" > "$DONE"; cp "$DONE" $TARS/driver_status/grep.DONE 2>/dev/null; }
trap on_exit 0 ; trap 'STATUS=killed; exit 130' 1 2 3 15
say(){ echo "@@@ $1 :: `date`"; }

# INSTALLED toolchain, not build-tree copies: /opt/gcc474 is the validated 4.7.4 and its specs
# auto-link -lunwind. GNU make is on /opt/gnu as BOTH make and gmake (the autotools depfiles
# bootstrap invokes bare `make`; HP make cannot do it).
PATH=/opt/gcc474/bin:/opt/gnu/bin:/usr/ccs/bin:/usr/bin:/bin ; export PATH
rm -rf $STAGE ; mkdir -p $STAGE

say "START grep build — compiler: `gcc --version | head -1`, make: `make --version | head -1`"

try_build(){    # $1=version  $2=extra LDFLAGS  $3=label
  V=$1 ; XLD=$2 ; LBL=$3
  SRC=$SRCROOT/$NAME-$V
  [ -d "$SRC" ] || { say "no source $SRC — skipping"; return 1; }
  # cd OUT of the build dir before removing it: on a failed attempt the shell's cwd is still inside
  # it, and HP-UX then refuses with "Device busy", leaving stale configure output for the next rung
  # to trip over (hit 2026-07-26 — grep 3.11 configured on top of 3.12's tree).
  BLD=$B/bld-$NAME ; cd $B || return 1 ; rm -rf $BLD ; mkdir -p $BLD ; cd $BLD || return 1
  say "----- grep-$V configure ($LBL) -----"
  # -O2 not -O3: ia64 -O3 is cursed across gcc versions on this box (proven repeatedly).
  # --disable-dependency-tracking: one-shot package build; also dodges the depfiles bootstrap trap.
  # --disable-perl-regexp: no libpcre on the box; -P would otherwise fail configure/link.
  CC="gcc $ABI" CFLAGS="-O2" LDFLAGS="-lunwind -lm $XLD" \
    $SRC/configure --prefix=$PREFIX --disable-dependency-tracking --disable-perl-regexp \
    > cfg.log 2>&1 || { say "grep-$V CONFIGURE failed ($LBL)"; tail -12 cfg.log; return 1; }
  say "grep-$V make ($LBL)"
  make > mk.log 2>&1 || {
    say "grep-$V BUILD failed ($LBL)"
    grep -i "implicit declaration of function .strlen" mk.log > /dev/null 2>&1 && \
      say "  ^^ THE modern-gnulib header-replacement signature — this version is not viable on 11.23"
    grep -i "Unsatisfied symbol" mk.log | head -5
    tail -15 mk.log
    return 1 ; }
  say "grep-$V make check ($LBL)"
  make check > chk.log 2>&1 ; CRC=$?
  # Judge by counts, not bare exit status: GNU testsuites have benign locale failures on 11.23.
  # keep the check log — the ladder overwrites $BLD on the next rung and we lose the evidence
  cp chk.log $B/chk-$NAME-$V-$LBL.log 2>/dev/null
  PASS=`grep "^PASS:" chk.log 2>/dev/null | sort -u | wc -l`
  FAILN=`grep "^FAIL:" chk.log 2>/dev/null | sort -u | wc -l`
  say "grep-$V check: rc=$CRC  PASS=$PASS  FAIL=$FAILN (distinct)"
  if [ "$FAILN" -gt 0 ] ; then
    echo "--- named failures (judge these, don't just count them) ---"
    grep "^FAIL:" chk.log | sort -u
    # keep each failing test's own log so the failure can be characterised without a rebuild
    for t in `grep "^FAIL:" chk.log | sort -u | sed 's/^FAIL: *//'` ; do
      for cand in tests/$t.log tests/$t tests/*/$t.log ; do
        [ -f "$cand" ] && cp "$cand" $B/failtest-$NAME-$V-`basename $t`.log 2>/dev/null
      done
    done
  fi
  if [ "$PASS" -eq 0 ] ; then say "grep-$V VACUOUS test run (0 passes) — reject"; return 1; fi
  if [ "$FAILN" -gt "$MAXFAIL" ] ; then say "grep-$V too many failures ($FAILN > $MAXFAIL) — reject"; return 1; fi
  say "grep-$V install DESTDIR=$STAGE"
  make install DESTDIR=$STAGE > ins.log 2>&1 || { say "install failed"; tail -10 ins.log; return 1; }
  BUILT="grep-$V ($LBL) PASS=$PASS FAIL=$FAILN"
  return 0
}

for V in $VERSIONS ; do
  if try_build $V "" "plain" ; then break ; fi
  say "===== retrying grep-$V with -lgnushim (11.23 libc gaps) ====="
  if try_build $V "-L/opt/gnu/lib -lgnushim" "gnushim" ; then break ; fi
  say "===== grep-$V rejected on both link variants — descending the ladder ====="
  BUILT=""
done

[ -z "$BUILT" ] && { STATUS="FAILED — no grep version built+checked on this box"; say "ALL RUNGS FAILED"; exit 1; }
say "★ BUILT: $BUILT — staged at $STAGE$PREFIX"
ls -la $STAGE$PREFIX/bin/grep $STAGE$PREFIX/bin/egrep $STAGE$PREFIX/bin/fgrep 2>/dev/null

say "===== ACCEPTANCE: the GNU features HP grep lacks ====="
G=$STAGE$PREFIX/bin/grep
printf 'alpha\nbeta\ngamma\ndelta\n' > /var/tmp/g.txt
echo "  -A context : `$G -A1 beta /var/tmp/g.txt | tr '\n' ' '`"
echo "  -B context : `$G -B1 gamma /var/tmp/g.txt | tr '\n' ' '`"
echo "  -o only    : `echo abcdef | $G -o 'cd'`"
echo "  -E altern  : `printf 'x\ny\n' | $G -E 'x|y' | tr '\n' ' '`"
echo "  BRE altern : `printf 'x\ny\n' | $G 'x\|y' | tr '\n' ' '`"
echo "  -r recurse : `$G -r beta /var/tmp/ 2>/dev/null | head -1`"
$G --version | head -1
STATUS="complete — $BUILT"
say "DONE"
