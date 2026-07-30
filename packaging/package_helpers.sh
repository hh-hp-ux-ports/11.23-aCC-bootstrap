#!/usr/bin/sh
# package_helpers.sh — build the HelperScripts serial depot.
#
# Admin helper scripts install to /opt/helpers/bin and the product SELF-REGISTERS that directory at
# the BACK of /etc/PATH (Hugo's spec: helpers must never shadow real tools).
#
# WHY THE PATH REGISTRATION IS BACK: revision 1.1 shipped configure/unconfigure control scripts that
# did this. 1.2 renamed the fileset scripts->RUN, kept only a postinstall, and DROPPED both — and
# swinstall.log shows 1.1 was never actually installed on the box, so /opt/helpers/bin has never once
# been in /etc/PATH. Every helper has been run by absolute path since. Any future revision that
# removes `configure` re-breaks this silently, so leave it in place.
#
# Master copies of every helper live in helper_scripts/bin on the share — that directory is the whole
# product, nothing is assembled from elsewhere. Add a script there, bump REV, re-run this.
#
# Run ON rx2620 as claude (non-root): swpackage can write a serial .depot file non-root; it CANNOT
# create a directory depot (SD ACL). Tools are in /usr/sbin.
SRC=/mnt/debianshare/helper_scripts/bin
REV=1.10
OUT=/mnt/debianshare/own_depots/HelperScripts-$REV-ia64-11.23.depot
PSF=/var/tmp/helpers.psf
export PATH=/usr/sbin:/usr/ccs/bin:/usr/bin:/bin
set -e

# --- control scripts -------------------------------------------------------------------------
# Deliberately no grep: HP-UX grep alternation is a known landmine here, and a shell `case` on a
# colon-padded copy of the PATH is both exact and dependency-free. Idempotent — reinstalling or
# updating never appends a second copy.
cat > /var/tmp/helpers_configure.sh <<"CFG"
#!/sbin/sh
# Append /opt/helpers/bin to the BACK of /etc/PATH (never the front: helpers must not shadow
# /usr/bin or the GNU toolchain). Idempotent. Must exit 0 or SD marks the fileset as failed.
P=`cat /etc/PATH 2>/dev/null` || exit 0
[ -n "$P" ] || exit 0
case ":$P:" in
  *:/opt/helpers/bin:*) exit 0 ;;                    # already registered
esac
cp -p /etc/PATH /etc/PATH.before-HelperScripts 2>/dev/null
echo "$P:/opt/helpers/bin" > /etc/PATH.tmp.$$ && mv /etc/PATH.tmp.$$ /etc/PATH
echo "HelperScripts: appended /opt/helpers/bin to /etc/PATH (takes effect at next login)"
exit 0
CFG

cat > /var/tmp/helpers_unconfigure.sh <<"UNCFG"
#!/sbin/sh
# Remove our /etc/PATH entry on swremove. Handles the entry in the middle, at the end, or alone.
[ -f /etc/PATH ] || exit 0
sed -e "s|:/opt/helpers/bin||g" -e "s|^/opt/helpers/bin:||" -e "s|^/opt/helpers/bin\$||" \
    /etc/PATH > /etc/PATH.tmp.$$ && mv /etc/PATH.tmp.$$ /etc/PATH
exit 0
UNCFG

# postinstall: file hygiene only — SD does not delete files that disappear between revisions, so
# obsolete helpers get removed here. PATH belongs in configure, not here.
cp /mnt/debianshare/helper_scripts/postinstall /var/tmp/helpers_postinstall.sh

chmod 755 /var/tmp/helpers_configure.sh /var/tmp/helpers_unconfigure.sh /var/tmp/helpers_postinstall.sh

# --- PSF -------------------------------------------------------------------------------------
# No recursive `file -r` exists in a PSF; generate one explicit line per script from find.
SCRIPTS=`( cd "$SRC" && find . -type f | sed "s|^\./||" | sort ) | tr "\n" " "`
{
  echo "vendor"
  echo "  tag LOCAL"
  echo "  title Hugo's rx2620 admin helper scripts"
  echo "end"
  echo "product"
  echo "  tag HelperScripts"
  echo "  revision $REV"
  echo "  title rx2620 admin helpers ($SCRIPTS) in /opt/helpers/bin, self-registered on /etc/PATH"
  echo "  architecture HP-UX_B.11.23_IA64"
  echo "  machine_type ia64*"
  echo "  os_name HP-UX"
  echo "  os_release ?.11.23"
  echo "  directory /opt/helpers"
  echo "  is_locatable true"
  echo "  fileset"
  echo "    tag RUN"
  echo "    revision $REV"
  echo "    title helper scripts"
  echo "    directory $SRC = /opt/helpers/bin"
  echo "    file_permissions -o bin -g bin -m 0555"
  echo "    postinstall /var/tmp/helpers_postinstall.sh"
  echo "    configure /var/tmp/helpers_configure.sh"
  echo "    unconfigure /var/tmp/helpers_unconfigure.sh"
  ( cd "$SRC" && find . -type f | sed "s|^\./||" | sort ) | while read f ; do
    echo "    file $f $f"
  done
  echo "  end"
  echo "end"
} > "$PSF"

rm -f "$OUT"
swpackage -s "$PSF" -x target_type=tape -d "$OUT"

echo "=== verify: control scripts must list configure + unconfigure + postinstall ==="
swlist -s "$OUT" -l fileset -a revision -a control_files
echo "=== verify: files ==="
swlist -s "$OUT" -l file | grep -v "^#"
echo "HELPERS-DEPOT-OK"
