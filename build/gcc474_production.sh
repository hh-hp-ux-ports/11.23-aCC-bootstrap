#!/usr/bin/sh
# build_gcc474_production.sh — rebuild the aCC-rooted gcc 4.7.4 with PRODUCTION paths so it can
# finally be packaged, then package it AND the aCC-rooted assembler into one depot.
#
# WHY A REBUILD IS NEEDED AT ALL (the recorded packaging blocker): 4.7.4 #2 was configured with a
# private prefix and --with-as=/home/claude/build/hpcc-bu246/bin/as. `--with-as` is an ABSOLUTE PATH
# COMPILED INTO THE DRIVER and does NOT relocate — proven on-box: the gcc tree itself relocates fine,
# but -print-prog-name=as still returns the build path, and with that file hidden the driver has NO
# working fallback (falls into HP `as` -> "error 2006: multiple source files"). -B cannot redirect it.
# So a depot built from that tree would hunt for an assembler in a home directory.
#
# REVISION CONVENTION (Hugo 2026-07-26): our builds of upstream X are <upstream>-hh<n> ('hh' = his
# initials), reusing the UPSTREAM-EQUIVALENT PRODUCT TAG so SD sees different revisions of the SAME
# software. Verified on-box: SD compares dot-separated components, so 2.46.1-hh1 ranks NEWER than
# 2.46.1 and -hh2 newer than -hh1. (-RC1 also sorts newer, which contradicts what RC means -> not used.)
#
# QUEUED behind the grep build (single CPU; also keeps `make check` verdicts uncontaminated).
NAME=gcc474p
B=/home/claude/build ; TARS=/mnt/debianshare/gnu_tarballs
SRC=/mnt/debianshare/hp-bootstrap-src/gcc-4.7.4   # NOT under gnu_tarballs — the aCC chain builds from here
HOST=$B/hpcc474v2                    # the VALIDATED aCC-rooted 4.7.4 #2 (stage2==stage3) hosts this
MLIB=$B/hpcc-mlib                    # ILP32 math libs — see ABI TRAP below
ASDIR=/opt/gnu/binutils2461          # aCC-rooted assembler, SD-installed, stable path
PFX=/opt/gnu/gcc474                  # Hugo's scheme: /opt/gnu/<tool><versiondigits>
STAGE=$B/stage-$NAME ; OBJ=$B/obj-$NAME
VER=4.7.4
DEPOT=/mnt/debianshare/own_depots/GNUhpchain-$VER-ia64-11.23.depot
LOG=$B/${NAME}.log ; DONE=$B/${NAME}.DONE
exec > $LOG 2>&1
STATUS=running
on_exit(){ rc=$?; echo "status=$STATUS rc=$rc when=`date`" > "$DONE"; cp "$DONE" $TARS/driver_status/${NAME}.DONE 2>/dev/null; }
trap on_exit 0 ; trap 'STATUS=killed; exit 130' 1 2 3 15
say(){ echo "@@@ $1 :: `date`"; }
fail(){ say "FAILED: $1"; STATUS="FAILED $1"; exit 1; }

say "QUEUED — waiting for the grep build to finish"
while [ ! -f $B/grep.DONE ] ; do sleep 60 ; done
say "grep finished: `cat $B/grep.DONE`"

PATH=$HOST/bin:/opt/gnu/bin:/usr/ccs/bin:/usr/bin:/bin ; export PATH
gcc --version 2>&1 | head -1 | grep "4\.7\.4" > /dev/null || fail "PATH gcc is not the chain 4.7.4"
[ -x $ASDIR/bin/as ] || fail "no assembler at $ASDIR/bin/as (is GNUbinutils2461 installed?)"
[ -d $SRC ] || fail "no gcc 4.7.4 source at $SRC"
say "host `gcc --version | head -1` ; as `$ASDIR/bin/as --version | head -1`"

rm -rf $OBJ $STAGE ; mkdir -p $OBJ ; cd $OBJ || fail cd
say "===== configure gcc $VER — PRODUCTION prefix $PFX, as=$ASDIR/bin/as ====="
# ABI TRAP (the canonical statement): a FULL bootstrap compiles stage2/3 with the NEW compiler at its
# NATIVE DEFAULT ABI, which is ILP32 on ia64-hpux. So CC/CXX must be plain gcc/g++ (NOT -mlp64) and
# the math libs must be the ILP32 set, or stage2 fails to link. -mlp64 governs stage1 only.
# STAGE1_CFLAGS -O2 is MANDATORY with a gcc>=4.7 host: the default -O0 stage1 emits every gnu-inline
# standalone -> 190MB .text > maxtsiz 96MB -> execv ENOMEM. BOOT_CFLAGS -O2: ia64 -O3 self-miscompiles
# gengtype (proven on this box, twice).
$SRC/configure --prefix=$PFX --with-local-prefix=$PFX \
  --enable-languages=c,c++ --enable-multilib --disable-shared --disable-nls \
  --with-system-libunwind --with-gnu-as --with-as=$ASDIR/bin/as \
  --with-gmp=$MLIB --with-mpfr=$MLIB --with-mpc=$MLIB \
  --disable-libgomp --disable-libssp --disable-libquadmath --disable-libatomic --disable-libitm \
  --enable-bootstrap CC=gcc CXX=g++ LDFLAGS="-lunwind -lm" \
  > cfg.log 2>&1 || { tail -25 cfg.log ; fail "configure" ; }
say "configure OK -> full 3-stage bootstrap (~3h40m on 1 CPU)"
make STAGE1_CFLAGS="-g -O2" BOOT_CFLAGS="-g -O2" > mk.log 2>&1 || {
  grep -i "comparison" mk.log | head -5 ; tail -25 mk.log ; fail "bootstrap"; }
say "★ bootstrap finished — stage2==stage3 comparison passed (make would have failed otherwise)"

make install DESTDIR=$STAGE > ins.log 2>&1 || { tail -15 ins.log ; fail "install"; }
say "staged to $STAGE$PFX"

say "===== GATE 1: the assembler binding must be the PRODUCTION path ====="
BOUND=`$STAGE$PFX/bin/gcc -print-prog-name=as`
echo "  -print-prog-name=as -> $BOUND"
case "$BOUND" in
  $ASDIR/bin/as) say "★ correctly bound to $ASDIR/bin/as" ;;
  *) fail "still bound to $BOUND — the whole point of this rebuild was to fix that" ;;
esac

say "===== GATE 2: NO out-of-range direct br.call (the HP ld defect found 2026-07-26) ====="
# HP ld B.12.34 fails to emit long-branch stubs in large executables: it emits direct br.call to
# addresses PAST _etext, which fault with SEGV_MAPERR when executed. It silently ruined a 37.6MB
# gcc 9.5 cc1plus (26 bad calls). gcc 4.7.4's binaries are smaller and have never shown it — but
# ASSUMING that is exactly the mistake this project keeps paying for, so check every binary.
OD=$ASDIR/bin/objdump
BAD=0
for f in `find $STAGE$PFX -type f -name "cc1*" ; find $STAGE$PFX/bin -type f 2>/dev/null` ; do
  N=`$OD -d $f 2>/dev/null | grep "br\.call" | grep -c "_etext"`
  [ "$N" -gt 0 ] && { say "  ⛔ $f has $N out-of-range direct call(s)"; BAD=`expr $BAD + $N`; }
done
[ "$BAD" -gt 0 ] && fail "HP ld emitted $BAD out-of-range branches — this compiler is silently broken"
say "★ no out-of-range branches in any shipped binary"

say "===== SPECS FIX: auto-link -lunwind (MANDATORY on 11.23, do this BEFORE gate 3) ====="
# 11.23 C++/EH links fail with "Unsatisfied symbol _Unwind_SetIP/..." because gcc is built
# --with-system-libunwind and ships no libgcc_eh, but its built-in specs never add -lunwind. The
# INSTALLED PROCURA gcc474 solves this with an installed specs FILE (not built-in specs — which is
# why `gcc -dumpspecs | grep lunwind` finds nothing there), carrying -lunwind appended to *lib:.
# Do the same so users need no wrapper and no manual -lunwind. Forgetting this failed gate 3 on the
# first run of this script.
SPECSD=$STAGE$PFX/lib/gcc/ia64-hp-hpux11.23/$VER
$STAGE$PFX/bin/gcc -dumpspecs > /var/tmp/specs.raw 2>/dev/null || fail "dumpspecs"
awk '/^\*lib:/ {print; getline; print $0 " -lunwind"; next} {print}' /var/tmp/specs.raw > $SPECSD/specs \
  || fail "writing specs"
grep -A1 "^\*lib:" $SPECSD/specs | tail -1 | grep -q "lunwind" || fail "specs fix did not take"
say "installed $SPECSD/specs with -lunwind on *lib:"

say "===== GATE 3: C and C++ smoke, BOTH ABIs (NO explicit -lunwind — the specs must supply it) ====="
echo 'int main(void){int i,s=0;for(i=1;i<=100;i++)s+=i;return s==5050?0:1;}' > /var/tmp/t.c
cat > /var/tmp/t.cpp <<'ENDCPP'
#include <vector>
#include <string>
#include <algorithm>
#include <cstdio>
int main(){ std::vector<std::string> v{"pear","apple","fig"};
  std::sort(v.begin(), v.end()); if (v.front()!="apple") return 1;
  printf("stl-ok\n"); return 0; }
ENDCPP
for A in "" "-mlp64" ; do
  L=${A:-ILP32}
  $STAGE$PFX/bin/gcc $A /var/tmp/t.c -o /var/tmp/t.bin && /var/tmp/t.bin || fail "C smoke $L"
  say "  C $L OK"
  # deliberately NO -lunwind here: if the specs fix above is missing this fails, which is the point
  $STAGE$PFX/bin/g++ $A -std=c++11 /var/tmp/t.cpp -o /var/tmp/t.xbin && /var/tmp/t.xbin || fail "C++ smoke $L (specs -lunwind fix missing?)"
  say "  C++/STL $L OK"
done

say "===== PACKAGE: one depot with BOTH aCC-rooted products ====="
PATH=/usr/sbin:$PATH ; export PATH
command -v swpackage >/dev/null 2>&1 || fail "swpackage not on PATH"
PSF=$B/${NAME}.psf
# Files for each product. RUN/DEV split per the standing convention.
cd $STAGE$PFX || fail "cd staged gcc"
cat > $PSF <<ENDPSF
vendor
  tag         GNUhp
  title        aCC-rooted GNU toolchain (pure HP provenance)
  description  Built from HP aC++ only: aCC -> binutils 2.24 -> gcc 3.4.6 -> gcc 4.7.4 -> binutils 2.46.1 -> gcc 4.7.4 (bootstrapped, stage2==stage3)
end

product
  tag          GNUbinutils
  title        GNU binutils 2.46.1 (LP64-hosted; aCC-rooted pure-provenance rebuild)
  revision     2.46.1-hh1
  architecture ia64-hpux
  machine_type ia64*
  os_name      HP-UX
  os_release   ?.11.23
  is_locatable true
  directory    $ASDIR
  fileset
    tag        RUN
    title      assembler and binary utilities
    directory  $ASDIR = $ASDIR
    file_permissions -u 022 -o bin -g bin
    file *
  end
end

product
  tag          GNUgcc474
  title        GCC $VER C/C++ (aCC-rooted pure provenance, full bootstrap stage2==stage3, bound to binutils 2.46.1)
  revision     $VER-hh1
  architecture ia64-hpux
  machine_type ia64*
  os_name      HP-UX
  os_release   ?.11.23
  is_locatable true
  directory    $PFX
  fileset
    tag        RUN
    title      compilers, drivers and runtime
    directory  $STAGE$PFX = $PFX
    file_permissions -u 022 -o bin -g bin
    file *
  end
end
ENDPSF
say "PSF written: $PSF"
rm -f $DEPOT
swpackage -s $PSF -x target_type=tape -d $DEPOT '*' > $B/${NAME}_pkg.log 2>&1 \
  || { tail -20 $B/${NAME}_pkg.log ; fail "swpackage"; }
[ -f "$DEPOT" ] || fail "no depot produced"
say "===== VERIFY the depot ====="
swlist -s $DEPOT -l product 2>/dev/null | grep -v "^#" | grep -v "^$"
ls -la $DEPOT
STATUS="complete — gcc $VER-hh1 (prefix $PFX, as=$ASDIR) + binutils 2.46.1-hh1 packaged in $DEPOT"
say "★★★ DONE."
say "  SAME TAGS as the PROCURA-rooted products, HIGHER revisions => SD sees them as newer versions"
say "  of the same software, not as unrelated products."
say "  Install as an UPDATE (replaces the PROCURA-rooted build, frees /opt/binutils and /opt/gcc474):"
say "     swin $DEPOT GNUbinutils,r=2.46.1-hh1"
say "     swin $DEPOT GNUgcc474,r=$VER-hh1"
say "  Install SIDE BY SIDE instead (both revisions live; keeps cross-validation):"
say "     swinstall -s <staged depot> GNUgcc474,r=$VER-hh1,l=$PFX"
say "  (is_locatable true is what makes the ,l= form legal.)"
