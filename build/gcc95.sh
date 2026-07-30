#!/usr/bin/sh
# build_gcc95.sh — RUNG 3 / THE DESTINATION: gcc 9.5.0, LP64, hosted by 4.8.5-nb.
# Host = 4.8.5-nb via the -lunwind wrappers ($BUILD/rung2bin), in LP64 (CC="gcc -mlp64"): uses the
# sound LP64 GMP/MPFR/MPC in rung2/hpux64, avoids 4.8.5-nb's ILP32 explow.c:86 ICE. gcc 9 needs only
# a C++98 host (4.8.5 qualifies). --disable-bootstrap single-pass first (per plan). Prefix /opt/gcc95.
# GNU sed on PATH (HP sed breaks s-header-vars). PATCHING likely (libstdc++ hpux / ia64 backend) —
# on failure the log keeps the exact error for triage; patches would go in gnu_tarballs/patches-gcc95-hpux/.
BUILD=/home/claude/build ; TARS=/mnt/debianshare/gnu_tarballs
SRC=$TARS/gcc-9.5.0
R2=$BUILD/rung2/hpux64
WRAP=$BUILD/rung2bin
OBJ=$BUILD/gcc95-obj ; PFX=/opt/gcc95     # NOTE: install to /opt/gcc95 needs root; build+DESTDIR-stage as claude
STAGE=$BUILD/gcc95-stage
LOG=$BUILD/gcc95.log ; DONE=$BUILD/gcc95.DONE
exec > $LOG 2>&1
STATUS=running
on_exit(){ rc=$?; echo "status=$STATUS rc=$rc when=`date`" > "$DONE"
  cp "$DONE" $TARS/driver_status/gcc95.DONE 2>/dev/null ; }
trap on_exit 0 ; trap 'STATUS=killed ; exit 130' 1 2 3 15
say(){ echo "@@@ $1 :: `date`" ; }
fail(){ say "FAILED: $1" ; STATUS="FAILED $1" ; exit 1 ; }
# wrappers first (gcc/g++ = 4.8.5-nb+unwind), then GNU sed/tar, gmake/gawk, then system
PATH=$WRAP:$BUILD/bin:/opt/gnu/bin:/usr/ccs/bin:/usr/bin:/bin:/usr/contrib/bin ; export PATH

[ -f $SRC/configure ] || fail "no gcc-9.5.0 source at $SRC (stage it on the dev box first)"
[ -f $R2/lib/libmpfr.a ] || fail "LP64 mpfr missing ($R2) — run rung2 first"
gcc --version | head -1 | grep 4.8.5 || fail "4.8.5-nb wrapper not first on PATH"
sed --version 2>/dev/null | grep -i gnu >/dev/null || fail "GNU sed not first on PATH"

say "configure gcc 9.5.0 (LP64, --disable-bootstrap, c/c++, multilib)"
rm -rf $OBJ ; mkdir -p $OBJ ; cd $OBJ || fail cd
$SRC/configure \
  --prefix=$PFX --with-local-prefix=/usr/local/ia64 \
  --enable-languages=c,c++ --disable-bootstrap --enable-multilib --disable-nls \
  --with-system-libunwind --with-gnu-as --with-as=/usr/local/ia64/bin/as \
  --with-gmp=$R2 --with-mpfr=$R2 --with-mpc=$R2 \
  --disable-libgomp --disable-libssp --disable-libquadmath --disable-libatomic --disable-libitm \
  --disable-libcc1 --disable-libsanitizer \
  CC="gcc -mlp64" CXX="g++ -mlp64" CFLAGS="-O2" CXXFLAGS="-O2" \
  > cfg.log 2>&1 || { tail -25 cfg.log ; fail configure ; }
say "CONFIGURE OK"

say "gmake (single-pass, LP64 — VERY LONG on 1 CPU)"
gmake > mk.log 2>&1 || { tail -45 mk.log ; fail "gmake (see mk.log — likely a patch point)" ; }
say "BUILD OK"

say "gmake install DESTDIR=$STAGE (staged; Hugo swinstalls the depot to real /opt/gcc95)"
rm -rf $STAGE ; gmake install DESTDIR=$STAGE > ins.log 2>&1 || { tail -15 ins.log ; fail "install" ; }

say "smoke test the staged gcc 9.5.0 (C + C++, both ABIs)"
G=$STAGE$PFX/bin/gcc ; GXX=$STAGE$PFX/bin/g++
export SHLIB_PATH=$R2/lib LD_LIBRARY_PATH=$R2/lib
$G --version | head -1 ; $G -dumpmachine
echo 'int main(void){return 0;}' > /tmp/n.c
printf '#include <iostream>\nint main(){ std::cout<<"gcc9-ok\\n"; return 0; }\n' > /tmp/n.cpp
$G          /tmp/n.c   -o /tmp/n    && /tmp/n    && say "C default OK"   || fail "C default"
$G   -mlp64 /tmp/n.c   -o /tmp/n64  && /tmp/n64  && say "C lp64 OK"      || fail "C lp64"
$GXX        /tmp/n.cpp -o /tmp/ncpp   && /tmp/ncpp   >/dev/null && say "C++ default OK" || fail "C++ default"
$GXX -mlp64 /tmp/n.cpp -o /tmp/ncpp64 && /tmp/ncpp64 >/dev/null && say "C++ lp64 OK"    || fail "C++ lp64"
STATUS="complete — gcc 9.5.0 staged at $STAGE$PFX (smoke OK, C+C++ both ABIs)"
say "★ RUNG 3 COMPLETE: gcc 9.5.0 built + smoke-tested. Package /opt/gcc95 depot next."
