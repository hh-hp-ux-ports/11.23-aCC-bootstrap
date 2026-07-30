# SD depot packaging (swpackage) on rx2620

Package built files into a swinstallable serial depot. Non-root can `swpackage` and `swlist`; only
`swinstall` (Hugo) needs root. Build the file set with `make install DESTDIR=<stage>` first.

## Single-product depot

PSF (`gnu_tarballs/<name>.psf` or under `/home/claude/build`). Key points: with an **absolute source
path you MUST add a `directory <src> = <dst>` mapping** or swpackage errors "cannot map to absolute
destination". `machine_type ia64*`, `os_release ?.11.23`.

```
vendor
  tag           GNU
  title         GNU Project / Free Software Foundation
end
product
  tag           GNUmake
  revision      4.4
  title         GNU Make 4.4 (ia64-hp-hpux11.23)
  architecture  HP-UX_B.11.23_IA64
  machine_type  ia64*
  os_name       HP-UX
  os_release    ?.11.23
  directory     /usr/local/ia64
  is_locatable  true
  fileset
    tag         runtime
    revision    4.4
    directory   /home/claude/build/stage64/usr/local/ia64 = /usr/local/ia64
    file -m 0555 -o bin -g bin bin/gmake              bin/gmake
    file -m 0555 -o bin -g bin lib/hpux64/libgmp.so.* lib/hpux64/
  end
end
```

Two output formats — pick by intent:
- **Directory-format depot (PREFERRED when the depot will be combined with others — Hugo 2026-07-20):**
  omit `target_type=tape` and point `-d` at a *directory*:
  ```
  swpackage -s <psf> -d /home/claude/build/<combined_depot_dir>
  ```
  Multiple `swpackage` runs into the **same** `-d` directory **accumulate** their products into one
  depot — so a set of tools meant to ship together (e.g. bzip2+xz+tar+sed+coreutils) goes straight
  into ONE directory depot with no separate merge step. This is the default for anything that will be
  merged: build directory depots and aggregate, don't make N separate `.depot` files and merge later.
- **Serial depot (single transportable file):** use `target_type=tape` when you specifically want one
  portable `.depot` file (e.g. a standalone single-product deliverable):
  ```
  swpackage -s <psf> -x target_type=tape -d /home/claude/build/<Name>-<ver>-ia64-11.23.depot
  ```
  A directory depot can be turned into a serial file later with `swpackage -s <dir> -x
  target_type=tape -d <file>.depot '*'` if a portable single file is needed for transport.

Verify (no root): `swlist -s <depot>` (products), `swlist -s <depot> -l file` (installed paths).
Then move the depot (directory or `.depot`) into `/mnt/debianshare/own_depots/`.

**GOTCHA (2026-07-20, fully worked out): making depots non-root — serial vs directory, and the NFS rule.**
- **`swpackage -x target_type=tape -d <file>.depot`** (SERIAL file) works fine as `claude` — always.
- **`swpackage -d <dir>`** (DIRECTORY format) fails non-root: `ERROR: Cannot create depot ... not
  authorized to create this depot` (SD ACL). Don't use swpackage for a directory depot non-root.
- **To build a DIRECTORY depot non-root, use `swcopy` (not swpackage) with the `@` target** — this DOES
  work as `claude` (nonprivileged mode uses its own admin area `/var/home/LOGNAME/sw`, so the polluted
  `/var/spool/sw` is irrelevant). **BUT swcopy refuses an NFS target** (`ERROR: This target is located
  on an NFS filesystem. It cannot be [used]`). So the working recipe is: **`swcopy -x
  run_as_superuser=false -s <local serial.depot> '*' @ <LOCAL dir depot>`** for each product
  (accumulates), then **`tar`-copy the finished local dir depot to the NFS share**. Fully non-root; no
  root, no `/var/spool/sw` cleanup needed. (Proven building `own_depots/interim_tools_gcc461` from the 6
  interim tools' serial depots, 2026-07-20.) NB: appending to an NFS dir depot LATER follows the same
  shape — copy it local, swcopy the new product `@` it, tar back to NFS (can't swcopy an NFS target).
- **PSF for a whole staged tree:** no working recursive `file -r` — generate explicit `file <rel> <rel>`
  lines from `find <stage> \( -type f -o -type l \)`.
- **`swpackage`/`swlist`/`swcopy` live in `/usr/sbin`** — put it on PATH in build scripts.

## Naming
`<Product>-<version>-ia64-11.23.depot` (e.g. `GNUmake-4.4-ia64-11.23.depot`). For noarch tools use
`machine_type *` and drop the ABI note.

## Both-ABI packaging
Map the LP64 staging into `lib/hpux64` + `include/`, the ILP32 staging into `lib/hpux32` +
`include/hpux32`, within one product (two filesets or two `directory =` maps), so one depot carries
both ABIs. Keep noarch tools (autoconf/automake/libtool scripts) as their own single noarch depot.

## Multi-product / combined depot (non-root)
Building fresh from one **multi-product PSF** (several `product` stanzas, one `swpackage` run) is the
simplest way to get one depot with several products — do this when you have the PSFs already. Add
`prerequisites <Prod>,r>=<v>` in a fileset to enforce install order (e.g. GMP before gcc), or a
`bundle` to install the set together.

**Merging existing, already-built depots** (not building fresh from a PSF) does NOT need root — see
the `hpux-merge-depots` skill. (Corrected 2026-07-19: `swcopy -x run_as_superuser=false` genuinely
works non-root for real product/fileset-level merging; it was previously assumed to need root because
its target is hard-wired to `/var/spool/sw` regardless of `-d`, which looked like a permission failure
but isn't — see that skill's `references/gotchas.md` for the full empirical trail.)

## Gotchas
- `swinstall`'s TUI is broken over SSH — always non-interactive (selections on the command line).
- **THE swinstall form (re-corrected 2026-07-22):** `swinstall -s <ABSOLUTE LOCAL path> <name>` —
  (1) **select by NAME** (product/bundle from `swlist -s <depot>`), not `\*`; (2) **STAGE NFS
  depots to local disk first** — Hugo reports NFS-source swinstall FREEZES (matches the observed
  15-min "Beginning Selection" stall); one lucky completion earlier briefly made the notes claim
  NFS-direct was fine — it isn't. Same local-staging rule as swcopy. The `swin` helper
  (HelperScripts depot → /opt/helpers/bin) wraps stage+install+cleanup. Add `-x` options only when
  actually needed (kernel products need `-x autoreboot=true` and a manual run).
- `make install` that re-links the running binary hits HP-UX `ETXTBSY` ("Text file busy") — package
  from a DESTDIR stage instead of a self-driven `make install`.
