#!/usr/bin/sh
# package_gnutools13.sh — GNUtools 1.3: the 1.2.x userland PLUS a new `nano` fileset
# (Hugo 2026-07-27: "build and package nano to the gnu tools depot").
#
# Derived from package_gnutools.sh (which produced GNUcombined 1.2.4). TWO deliberate differences:
#  1. GNUtools ONLY. 1.2.4 also carried GNUgcc474 + GNUbinutils + htop products, but the compiler's
#     packaging tree /var/tmp/reloc/opt/gcc474 no longer exists (/var/tmp was cleared and the box
#     rebooted), and those products are ALREADY INSTALLED — nothing needs them re-shipped to add an
#     editor. Their own depots remain in own_depots/ if they ever need re-delivery.
#  2. New fileset `nano` from the build_nano.sh staging tree.
#
# Everything else is unchanged on purpose: same /opt/gnu prefix, same RUN/DEV split, same dedup of
# paths several tools provide (share/info/dir, lib/charset.alias, locale dirs) — kept in the FIRST
# fileset that provides them, dropped from later ones, or swinstall installs colliding duplicates.
D=/mnt/debianshare/own_depots/interim_tools_gcc461
STAGE12=/home/claude/build/gnutools12-stage      # make+gawk rebuilt with the VALIDATED gcc 4.7.4
SHIMSTAGE=/home/claude/build/shimext-stage       # ncurses runtime + gnulib shim
NANOSTAGE=/home/claude/build/stage-nano          # from build_nano.sh (DESTDIR staging)
REV=1.3
OUT=/mnt/debianshare/own_depots/GNUtools-$REV-ia64-11.23.depot
PSF=/var/tmp/gnutools13.psf
SEEN=/var/tmp/gnutools13.seen
export PATH=/usr/sbin:/usr/ccs/bin:/usr/bin:/bin

# GNU tools are the SYSTEM DEFAULT — configure PREPENDS /opt/gnu/bin to /etc/PATH (front position,
# idempotent: strips any existing occurrence first). HP originals stay reachable by full path.
cat > /var/tmp/gnu_configure.sh <<"CFG"
#!/sbin/sh
P=`sed -e "s|:/opt/gnu/bin||g" -e "s|^/opt/gnu/bin:||" -e "s|^/opt/gnu/bin$||" /etc/PATH`
if [ -n "$P" ] ; then echo "/opt/gnu/bin:${P}" > /etc/PATH ; else echo "/opt/gnu/bin" > /etc/PATH ; fi
exit 0
CFG
cat > /var/tmp/gnu_unconfigure.sh <<"UNCFG"
#!/sbin/sh
sed -e "s|:/opt/gnu/bin||g" -e "s|^/opt/gnu/bin:||" /etc/PATH > /etc/PATH.gnu.$$ &&
  cat /etc/PATH.gnu.$$ > /etc/PATH ; rm -f /etc/PATH.gnu.$$
exit 0
UNCFG
chmod 755 /var/tmp/gnu_configure.sh /var/tmp/gnu_unconfigure.sh

set -e
[ -x "$NANOSTAGE/opt/gnu/bin/nano" ] || { echo "MISSING nano stage $NANOSTAGE/opt/gnu/bin/nano" >&2 ; exit 1 ; }
: > "$SEEN"

DEVPAT="^include/|^lib/.*\.a$|^lib/.*\.la$|^lib/pkgconfig/"
HTOPPAT="^bin/htop$"
TOOLS="bash GNUtar xz bzip2 GNUcoreutils GNUsed make gawk ncursesshim nano"

srcof() {   # tool -> staging tree rooted so that its contents map onto /opt/gnu
  case $1 in
    make|gawk)   echo $STAGE12/$1/opt/gnu ;;
    ncursesshim) echo $SHIMSTAGE/opt/gnu ;;
    nano)        echo $NANOSTAGE/opt/gnu ;;
    *)           echo $D/$1/runtime/usr/local/ia64 ;;
  esac
}
fsof() {    # tool -> fileset tag (real product names, not our internal tree names)
  case $1 in
    GNUtar) echo tar ;; GNUcoreutils) echo coreutils ;; GNUsed) echo sed ;;
    ncursesshim) echo ncurses ;; *) echo $1 ;;
  esac
}

{
  echo "vendor"
  echo "  tag LOCALGNU"
  echo "  title Locally built GNU tools for HP-UX 11.23 (LP64 -O2; built by the validated gcc 4.7.4)"
  echo "end"
  echo "product"
  echo "  tag GNUtools"
  echo "  revision $REV"
  echo "  title GNU userland for HP-UX 11.23 ia64 (bash tar xz bzip2 coreutils sed make gawk ncurses nano shim) under /opt/gnu"
  echo "  architecture HP-UX_B.11.23_IA64"
  echo "  machine_type ia64*"
  echo "  os_name HP-UX"
  echo "  os_release ?.11.23"
  echo "  directory /opt/gnu"
  echo "  is_locatable true"
  for T in $TOOLS ; do
    SRC=`srcof $T` ; FS=`fsof $T`
    [ -d "$SRC" ] || { echo "MISSING $SRC" >&2 ; exit 1 ; }
    echo "  fileset"
    echo "    tag $FS"
    echo "    revision $REV"
    echo "    directory $SRC = /opt/gnu"
    echo "    file_permissions -o bin -g bin"
    echo "    configure /var/tmp/gnu_configure.sh"
    echo "    unconfigure /var/tmp/gnu_unconfigure.sh"
    ( cd "$SRC" && find . \( -type f -o -type l \) | sed "s|^\./||" ) | grep -vE "$DEVPAT" | grep -vE "$HTOPPAT" | while read f ; do
      if grep -x "$f" "$SEEN" > /dev/null 2>&1 ; then
        :
      else
        echo "$f" >> "$SEEN"
        echo "    file $f $f"
      fi
    done
    echo "  end"
  done
  # ---- the single dev fileset: headers + static libs + pkgconfig from every tool tree ----
  echo "  fileset"
  echo "    tag dev"
  echo "    revision $REV"
  echo "    title development files (headers, static libs, pkgconfig) for the GNU userland"
  echo "    file_permissions -o bin -g bin"
  for T in $TOOLS ; do
    SRC=`srcof $T`
    echo "    directory $SRC = /opt/gnu"
    ( cd "$SRC" && find . \( -type f -o -type l \) | sed "s|^\./||" ) | grep -E "$DEVPAT" | while read f ; do
      if grep -x "$f" "$SEEN" > /dev/null 2>&1 ; then
        :
      else
        echo "$f" >> "$SEEN"
        echo "    file $f $f"
      fi
    done
  done
  echo "  end"
  echo "end"
} > "$PSF"

echo "PSF lines: `wc -l < $PSF`"
rm -f "$OUT"
swpackage -s "$PSF" -x target_type=tape -d "$OUT"
echo "=== verify: filesets ==="
swlist -s "$OUT" -l fileset -a revision
echo "=== verify: nano is in there ==="
# NB: swlist pads every path with trailing whitespace, so a "$" anchor here silently
# matches nothing and makes a good depot look empty. Match without the anchor.
swlist -s "$OUT" -l file 2>/dev/null | grep -E "bin/(nano|rnano)[[:space:]]*$"
echo "GNUTOOLS13-DEPOT-OK"
