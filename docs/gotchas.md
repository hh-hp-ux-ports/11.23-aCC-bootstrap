# HP-UX 11.23 (ia64) build gotchas — check BEFORE configuring

Each entry is a real failure hit on rx2620 with the cause and the fix. Apply the relevant ones up
front; add new ones here when a build surfaces something not listed.

## Toolchain / compiler
- **gcc 4.6.1 `-O3` MISCOMPILES on ia64.** A `-O3`-built `m4` linked fine but *segfaulted at
  runtime*. Fix: build everything compiled by **gcc 4.6.1 at `-O2`**. Only gcc 4.8.5's own later
  bootstrap stages (compiled by the new 4.8.5) may use `-O3` (`BOOT_CFLAGS=-O3`, `STAGE1_CFLAGS=-O2`).
- **C++ / exception handling fails to link: `ld: Unsatisfied symbol _Unwind_SetIP/...`.** gcc 4.6.1
  was built `--with-system-libunwind` and ships no `libgcc_eh`; its spec doesn't auto-add `-lunwind`.
  The unwinder IS present (`/usr/lib/hpux{32,64}/libunwind.so`). Fix: add **`-lunwind`** to LDFLAGS
  (harmless on C links). Needed for anything using C++/iostream/exceptions, incl. GMP `--enable-cxx`
  and building gcc 4.8.5 (which is C++). Verified in both ABIs.
- **`ld: Unsatisfied symbol _Isinf` (or other math syms).** gnulib code uses `isinf`→HP `_Isinf` in
  **libm**, but gnulib mis-detects 11.23 ("future OS version") and omits `-lm`. Fix: add **`-lm`** to
  LDFLAGS (so use `LDFLAGS="-lunwind -lm"` by default).
- **HP native `cc` needs `-Ae`** (ANSI + HP extensions) to compile GNU/portable C. `+DD64` = LP64,
  `+DD32` = ILP32 (default). Use `cc -Ae` as the base for HP-cc bootstraps.
- **⚠️ ITANIUM TRAPS UNALIGNED ACCESS — and x86-tuned packages assume it is free.** The failure is a
  clean **SIGBUS at runtime** (`rc=138`, "Bus error (core dumped)"), not a build error, so a package
  can compile perfectly and then die on every invocation. Proven on **zstd 1.5.7** (2026-08-05):
  ```c
  #ifndef MEM_FORCE_MEMORY_ACCESS
  #  ifdef __GNUC__
  #    define MEM_FORCE_MEMORY_ACCESS 1     /* "compiler extension for unaligned access" */
  ```
  i.e. compiling with ANY gcc made zstd assume unaligned loads are safe. Fix was its own portable
  path: **`-DMEM_FORCE_MEMORY_ACCESS=0 -DXXH_FORCE_MEMORY_ACCESS=0`** (bundled xxhash repeats the
  pattern). ⇒ When a freshly built tool SIGBUSes immediately, look for a `FORCE_MEMORY_ACCESS` /
  `UNALIGNED` / packed-struct knob before suspecting the compiler. Hash/compression/codec libraries
  are the usual offenders.
- **⚠️ A package may not define `install` for HP-UX at all.** zstd gates its install rules behind an
  explicit platform filter (`ifneq (,$(filter Linux Darwin … AIX MSYS_NT%,$(UNAME)))`); `uname` here
  returns **`HP-UX`**, which is absent, so `make install` fails with *"No rule to make target
  'install'"* even though the build succeeded. Adding `HP-UX` to that filter is enough — the existing
  rules need no other change. Check for this before concluding a staging failure is your own.

## Building gcc 4.8.5 itself
- **`internal compiler error: in plus_constant, at explow.c:86`** while building **libgomp** (OpenMP
  runtime) — a known gcc-4.8-on-ia64 ICE from libgomp's thread-local addressing. Not a sign the
  compiler is broken; it builds its core + libgcc fine. FIX: **`--disable-libgomp`** (we don't need
  OpenMP), and trim other unneeded target runtimes: `--disable-libssp --disable-libquadmath
  --disable-libatomic --disable-libitm`. For a C-only compiler you only need libgcc.
- **gcc 4.8.5 `-O3` ICEs on ia64 too** — `internal compiler error: in expand_shift_1, at
  expmed.c:2245` when the new gcc compiles `optabs.c` at `-O3` (hit during a `BOOT_CFLAGS=-O3`
  bootstrap). So **bootstrap gcc at `-O2`** (`STAGE1_CFLAGS=-O2 BOOT_CFLAGS=-O2`); `-O2` is the safe
  level on this box for any gcc. (This walks back "gcc 4.8.5 → always -O3".)
- **Bootstrap host must have g++** — the 3-stage bootstrap compiles gcc's own C++ source, so a
  C-only gcc (like our "simple" probe) can't host it. Host with gcc 4.6.1 (has g++ + `-lunwind`).
- gcc needs a **working awk** (HP awk regex-fails on `opth-gen.awk` → `s-options-h` Error 2) and a
  working **gmake** on PATH; put gawk (3.1.8 stopgap) + our gmake first in PATH.
- Reuse existing LP64 GMP/MPFR/MPC via the split flags `--with-gmp-include=/usr/local/ia64/include
  --with-gmp-lib=/usr/local/ia64/lib/hpux64` (same for mpfr/mpc) — matches the LP64 `gmp.h`.

## Missing libc functions (11.23 predates POSIX-2001 bits)
- **No `setenv`/`unsetenv`** (has `putenv`; they arrived in 11.31). gnulib-based packages
  (m4, autoconf, coreutils, grep, tar…) bundle their own replacement and build fine. Packages that
  do NOT bundle gnulib and call setenv directly (e.g. **modern gawk's `debug.c`**) fail with
  `ld: Unsatisfied symbol setenv`. `ac_cv_func_setenv=no` alone does NOT help if there's no bundled
  replacement. Fixes, in order of preference: (a) use an **older version that doesn't use it** (e.g.
  **gawk 3.1.8** predates `debug.c`); (b) link a gnulib `libgnu.a` providing setenv/unsetenv; (c) a
  small putenv/environ shim. Watch for other 11.23-missing POSIX funcs surfacing the same way.

## Archives / extraction — ✅ RESOLVED. The box has GNU tar/xz/bzip2 INSTALLED. Stop saying it doesn't.

**Measured on-box 2026-08-10** (Hugo had to correct me twice in one session for claiming otherwise):

| tool | path | note |
|---|---|---|
| **GNU tar 1.35** | `/opt/gnu/bin/tar` | reads `@LongLink` long paths fine |
| xz | `/opt/gnu/bin/xz` | |
| bzip2 | `/opt/gnu/bin/bzip2` | |
| **gzip / gunzip** | `/usr/contrib/bin/` | ⚠️ **NOT** in `/opt/gnu/bin` — the one real gap |
| zstd | *not installed* | built, depot not yet packaged/installed |

⇒ **Extract directly on rx2620.** `.tar.gz`, `.tar.bz2`, `.tar.xz` and long-path archives all work
(tar shells out to the compressor, and all three are present). Converting tarballs on the dev box, or
extracting there "because HP tar can't", is obsolete advice — the only reason left to stage on the
dev box is convenience (it has the internet), not capability.

⚠️ **The lesson is bigger than tar.** This entry was marked "LARGELY OBSOLETE" for three weeks while
the stale sentence underneath it stayed readable, and it got repeated as fact. **A stale claim about
a MISSING tool is self-reinforcing**: it stops you running the command that would disprove it. Before
writing "the box has no X", run `command -v X` or check `ls /opt/gnu/bin` — one cheap command against
an inventory that changes every time a depot is installed. The full `/opt/gnu/bin` listing is ~180
entries including coreutils, gawk, sed, grep, bash, nano, htop, find/xargs/locate, make, ncurses.

## More missing/mis-detected libc functions (found 2026-07-20 building interim tools)
- **`memmem` is DECLARED but NOT implemented on 11.23** → `ld: Unsatisfied symbol "memmem"`. gnulib's
  configure checks `HAVE_DECL_MEMMEM` (finds the header declaration → `=1`) and sets `REPLACE_MEMMEM=0`,
  so it does NOT build its own `memmem.o` — then the link fails because libc has no actual `memmem`.
  Hit building **coreutils 9.11** (`src/cut.c` uses memmem). Tried `ac_cv_func_memmem=no` — **did NOT
  work** (coreutils failed at the identical `src/cut` memmem link error), because the real problem is
  deeper (see next).
- **`getopt.h: No such file or directory`** building **sed 4.9** (`sed/sed.c`). 11.23 has no `getopt.h`
  (getopt is in `unistd.h`, no getopt_long); gnulib decided the system getopt was fine and did NOT
  generate its `lib/getopt.h` replacement → compile fails.

## ⚠️ BIG FINDING (2026-07-20): modern gnulib's `<string.h>`/header-replacement wrapper is BROKEN on 11.23 + gcc 4.6.1 — don't build bleeding-edge GNU tools here
The tell: **`lib/renameatu.c: warning: implicit declaration of function 'strlen'`** while building
coreutils 9.11. `strlen` is always in libc and needs no gnulib replacement — if even IT isn't declared,
gnulib's generated `<string.h>` wrapper (which `#include_next`s the real header and re-declares funcs)
is not pulling in the system declarations at all on this 2004 OS + gcc 4.6.1. That's why `memmem`
persisted despite `ac_cv_func_memmem=no`, and why per-function `ac_cv_func_*=no` overrides are
whack-a-mole against a broken foundation. **Conclusion: don't fight modern gnulib here.** For sed and
coreutils use **older, more-portable versions contemporary with 11.23's era** — e.g. **sed 4.2.2 (2012)
/ 4.5 (2018)**, **coreutils 8.x (≤8.32, 2020)** — which predate this aggressive header-replacement and
build cleanly on old Unix. (This is an OS+gnulib issue, largely independent of compiler, so gcc 4.8.5
won't necessarily rescue 9.11/4.9 either — prefer older versions regardless. bzip2/xz/tar have little/no
gnulib and build fine on modern versions.)

## Source staging / NFS
- **Extracted source files must be world-readable for the rx2620 side to compile them** — some GNU
  tarballs ship individual files with restrictive modes (e.g. bash 5.0's `lib/glob/smatch.c` is `0600`).
  Over NFS, rx2620's `claude` (uid mapped) then can't read them → `cc1: fatal error: <file>: Permission
  denied` mid-build. FIX: after extracting on the dev box, **`chmod -R a+rX <srcdir>`** so every file
  is readable and dirs traversable. (Only bit one file in bash so most builds don't hit it, but it's a
  silent landmine — do the chmod as part of staging. `stage_source.sh` should include it.)

## bash 5.0 specifics (built 2026-07-20 with gcc 4.6.1, LP64, -O2 — SUCCESS, but 3 traps)
bash 5.0.18 (bash-5.0 + 18 patches) builds + runs clean on 11.23 (version `5.0.18(1)-release`). Traps:
- **One source file ships mode 0600** (`lib/glob/smatch.c`) → `cc1: Permission denied` over NFS. Fix:
  `chmod -R a+rX` the source after extraction (see "Source staging / NFS" above).
- **`make tests` leaves ORPHANED, HUNG bash test processes** (`histexp5.sub`, `procsub.tests` — process
  substitution / history expansion tests that don't terminate on HP-UX; they reparent to init and keep
  running). They hold the `bash` binary open → the next step's relink `rm -f bash` hits HP-UX **ETXTBSY
  "Text file busy"** and `make install` fails. Fix: after tests, **kill the stray
  `ps -ef | grep bash-<ver>-obj/bash` processes**, then `touch <obj>/bash <obj>/bashbug` (so make won't
  relink), then `make install`. (Consider `make` without `tests`, or a timeout on tests, to avoid the
  hang entirely.)
- **`examples/loadables/fdflags.c: 'O_CLOEXEC' undeclared`** — 11.23 lacks `O_CLOEXEC`; this is an
  optional example loadable builtin, NOT bash itself, and bash's install target ignores it
  (`Error 2 (ignored)`). Harmless — bash + all real builtins install fine.

## Build tools
- **autotools `config.status` "Something went wrong bootstrapping makefile fragments for automatic
  dependency tracking"** (seen with **sed 4.9**). The depfiles bootstrap invokes bare `make` — if only
  `gmake` (not `make`) is on PATH, it falls through to HP `/usr/bin/make` which can't do it, and
  `config.status` exits 1. FIX: provide a `make`→GNU-make on PATH (copy/link our gmake to `bin/make`,
  not just `bin/gmake`) AND/OR pass **`--disable-dependency-tracking`** to configure (dependency
  tracking is only for incremental dev rebuilds; a one-shot package build doesn't need it). Do both to
  be safe. (xz/tar happened not to trip this; sed's automake version did.)
- **HP `/usr/bin/make` can't build GNU packages** — use **`/opt/gnu/bin/gmake`** (GNU Make 4.4.1, from
  our GNUtools depot). ⚠️ The old path `/home/claude/build/make-4.4/make` is GONE — that whole build
  tree was deleted 2026-08-05 when `/home` was cleared for tape backup. On a stock box with no gmake
  yet, build it via its `build.sh`, which needs no pre-existing make. **GOTCHA: `build.sh` requires
  `./configure` to have run FIRST** (it reads the configure-generated `build.cfg`; otherwise instant
  `./build.cfg: not found`).

- **HP `/usr/bin/awk` is broken for build scripts** — regex errors on gcc's `opth-gen.awk`
  (`awk: There is a regular expression error` → gcc `s-options-h` fails). Provide a real awk on PATH:
  **gawk** (older 3.1.8 builds self-contained) or **mawk** (tiny, no deps); gcc's configure accepts
  either. Without one, gcc 4.8.x `make` dies early.
- **automake 1.18 configure: "no POSIX shell good enough for testsuite"** — 11.23 has only HP
  `/bin/sh` + `/bin/ksh`, no bash. Fix: build **bash** first (bash 5.0 builds on 11.23) and point
  `CONFIG_SHELL` at it, or use an older automake with a laxer shell check.
- **perl on rx2620 = 5.8.0** (2002) — very new automake/autotools may reject it; fall back a version.
- **Use STABLE tool versions, not experimental** — e.g. autoconf **2.72** (2.73 self-warns
  "experimental"), libtool **2.4.7** (2.5/2.6 are development). Don't just grab the highest number.
- **autoconf 2.72 REQUIRES Perl ≥5.10 to run** (autom4te etc. — per its release notes; *users* of a
  generated configure need no perl). rx2620 has **perl 5.8.0** → running autoconf 2.72 there will
  fail. Options: (a) **autoconf 2.69** (perl 5.6 floor; automake 1.18 only needs autoconf ≥2.65, so
  they pair fine), or (b) build a newer perl first (perl has good HP-UX support, `README.hpux`).
- **gawk 5.4.x (Feb 2026) switched to the brand-new MinRX regex engine** — bleeding-edge 2026 code
  with zero HP-UX exposure, on top of gawk's existing setenv dependency. High-risk on 11.23; prefer
  an older gawk (5.1/4.2.1 + setenv shim, or the 3.1.8 stopgap) unless 5.4 proves itself.
- **m4 1.4.21 carries 2025-vintage bundled gnulib** — same broken-wrapper risk class as sed 4.9/
  coreutils 9.11. Fallbacks in order: m4 1.4.19 (2021, uncertain era) → **1.4.18 (2016, safe era)**.

## ⛔ COMMANDS THAT FAIL *SILENTLY* OR *VACUOUSLY* ON 11.23 (each one has cost real work)
The dangerous class here is not "command errors" — it is "command succeeds and returns nothing, or
writes nothing, and you believe the empty result". Verify against a control, never against a guess.
- **`tar czf` produces a 0-BYTE ARCHIVE *AND EXITS 0*.** GNU tar shells out to a compressor, and
  neither `gzip` nor `xz` is on a non-interactive PATH (`gzip`/`gunzip` are in **`/usr/contrib/bin`**,
  `xz` is in **`/opt/gnu/bin`**). Measured 2026-08-05, and the two behave DIFFERENTLY:
  ```
  tar czf  (gzip missing) -> rc=0  size=0   <-- SILENT. `tar czf … && rm -rf src` DELETES YOUR SOURCE
  tar cJf  (xz   missing) -> rc=2  size=0       "Error is not recoverable: exiting now"
  ```
  **This destroyed 107 build logs on 2026-08-05**: stderr was discarded AND the exit code said
  success, so nothing signalled failure. ⇒ **Never gate a deletion on tar's exit status. Check the
  OUTPUT SIZE, and for anything irreplaceable list the members back.** FIX: plain
  `/opt/gnu/bin/tar cf` and compress as a separate step, or put `/usr/contrib/bin:/opt/gnu/bin` on
  PATH first — with PATH set, `tar cJf` works normally.
- **LZMA2 IS available: `/opt/gnu/bin/xz` 5.4.7** (from GNUtools), so `.xz` is a usable archive format
  here; `xz -9` round-trips byte-identically and `xz -t` verifies. Box has no `zstd`, no `7z`.
- **HP `find` has no `-maxdepth`** (nor `-mmin`, nor `-newermt`). It does not error usefully in a
  pipeline — it just yields nothing, so `find ... -maxdepth 1 | wc -l` confidently reports **0**.
  ✅ **GNU findutils 4.10.0 IS NOW INSTALLED** (confirmed 2026-08-10): `/opt/gnu/bin/find`,
  `xargs`, `locate`, `updatedb`. Use the absolute path or put `/opt/gnu/bin` first on PATH —
  bare `find` still resolves to HP's, since `/usr/bin` leads the default PATH. With GNU find
  `-maxdepth`/`-mmin`/`-newermt`/`-print0` all work normally.
  (Pre-findutils substitutes, still valid if you are ever on HP's: `ls -p | grep '/$'` for
  directories at depth 1, `ls -p | grep -v '/$'` for files, and a reference file + `find -newer`
  in place of `-mmin`.)
- **`swlist -a is_protected` renders NOTHING unless products are named explicitly.** `swlist -s <depot>
  -l product -a is_protected` prints bare product names with an empty column; the attribute only
  appears when you list products by name (and request `-a revision` alongside). Counting `true`/`false`
  over the un-named form yields 0/0 and means nothing.
- Related, already known: `which` exits 0 even when it finds nothing; HP `grep` lacks `-A`/`-B`;
  `strings` needs `-a` to see `.note`; `/usr/bin/sh`'s `echo` expands backslash escapes (use a
  heredoc). **Reach for `/opt/gnu/bin/<tool>` by FULL PATH** — a non-interactive `ssh rx2620 'cmd'`
  does not read `/etc/PATH`, so `/opt/gnu/bin` is absent and a bare `md5sum`/`grep` silently gets the
  HP one or nothing.
## Upstream reality check (researched 2026-07-20) — nobody is coming to help
- **ia64-hpux is an OBSOLETE gcc configuration**: bugs filed against it get SUSPENDED unfixed (e.g.
  PR target/63545, an ICE building gcc for ia64-hp-hpux11.23). GCC 14 obsoleted all ia64; the 2024
  un-deprecation rescued only ia64-*linux* — hpux/vms/elf stayed obsolete. No upstream fix for our
  explow.c/expmed.c ICEs will ever come; version-stepping and local workarounds are the only paths.
- **Last upstream test reports for ia64-hp-hpux11.23 are ~gcc 4.5.2 (Oct 2010)** — gcc 4.8.5 was
  likely never fully validated on this exact target. Our ICEs are plausibly virgin territory.
- **Field precedent for the 4.7.4 stepping-stone (PR64919 thread, 2015)**: someone built gcc 4.7.4
  on ia64-hpux (needed a patch) and hosted 4.9.2 with it — 4.9.2 then FAILED in libstdc++ (C++11-era
  type_traits/future template errors). Take-away: 4.7.4 is a proven-buildable rung; going PAST 4.8.x
  (4.9+, 9.x) hits libstdc++ modernity walls — treat the "gcc 9.5 via 4.8.5" contingency as long-odds.
- **gnulib officially lists ALL HP-UX (even 11.31) under "Formerly Supported Platforms"** — the
  BIG FINDING above is confirmed policy, not a local fluke. Era-appropriate versions are the
  permanent strategy on this box. (Nuance: tar 1.35 (2023) bundles lots of gnulib yet built fine —
  the breakage depends on which replacement headers a package's module set generates, so keep the
  newest→oldest fallback loop rather than assuming a hard year cutoff.)
- **GMP on ia64-hpux ABI=32**: historically `mpz_popcount`/`mpz_hamdist`/`mpn_popcount` misbehave
  (segfault) with certain compilers, and long-long-limb ABIs see spurious `t-perfpow` test noise —
  run `make check` for BOTH ABIs and judge failures individually (GMP 6.3.0's Known-Build-Problems
  page lists nothing ia64-hpux-specific, so 6.3.0 + gcc is expected to pass).

## Non-obvious mechanics
- **Single CPU** → no `-j`; long builds; always run detached with the sentinel (below).
- **Background SSH polling is unreliable** for detecting completion — use the exit-trap `.DONE`
  sentinel that `scripts/build_template.sh` writes, and check `[ -f *.DONE ] && cat *.DONE`.
- **NON-root**: can compile, `swpackage`, `swlist`; canNOT `mount`, `swinstall`, or write raw
  devices. Live installs are Hugo's (`swinstall`); we only ever produce depots.

## HP sed: the `-e 's/.../p' -e d` idiom silently returns NOTHING (proven 2026-07-22)
gcc's install recipe `s-header-vars` uses `sed < Makefile -e 's/^\([A-Z0-9_]*_H\)[ 	]*=.*/\1/p' -e d`
(p-flag + explicit delete, no -n). **HP /usr/bin/sed: 0 lines. GNU sed: 116 lines. Same input.**
No error — just silence → `move-if-change tmp-header-vars` dies with "cannot access", failing
`gmake install` AFTER a fully successful bootstrap. (The `-n ... /p` form DOES work in HP sed —
it's specifically p-then-d that's broken.) FIX: put `/opt/gnu/bin` before /usr/bin on PATH for any
gcc build/install (cascade driver line 62 does). This is the FOURTH distinct HP-tool inadequacy to
break a gcc build (awk regex, tar @LongLink, sed context-flags, now sed p-then-d).

## gawk's pty tests HANG FOREVER on 11.23 (2026-07-22)
gawk 5.1.1 `make check`: test `pty2` sat 95+ minutes with ZERO CPU across all three of its
processes (`sh -c`, `gawk -f pty2.awk`, a helper gawk) — a hard hang in HP-UX pseudo-terminal
semantics, not slowness. The rest of the 539-test suite ran normally. Fix: kill the pty test's
process group; the harness marks it failed and continues (pty1 completed; pty2 hung — treat both
as hang-suspect). Report the killed test honestly in results. Consider `GAWK_TEST_ARGS` or
deleting pty tests from the target list on future gawk builds rather than babysitting.

## vsnprintf(NULL, 0, ...) SEGFAULTS on 11.23 — the C99 measuring idiom is lethal (2026-07-23)
HP-UX 11.23 libc predates C99 conformance here: `vsnprintf(NULL, 0, fmt, ap)` (and
`snprintf(NULL, 0, ...)`) does NOT return the would-be length — it CRASHES (proven by direct
test). Any code using the classic measure-allocate-format idiom dies or corrupts memory; a
hand-rolled vasprintf built on it gave htop a heisenbug (heap-layout-dependent crash points at
exit — cost hours to trace 2026-07-23). ALSO: with a real but too-small buffer, truncation
returns -1 (pre-C99), not the needed length — growth loops must handle both conventions.
**Rule: never use the NULL/0 measuring idiom on 11.23. For allocating printf, link gnulib's
vasprintf from libgnushim (/opt/gnu/lib*/libgnushim.a, gnushim.h) — its vasnprintf machinery
does not depend on C99 snprintf semantics.** When porting: grep sources for `snprintf(NULL`
and `vsnprintf(NULL` up front.

## Binutils/toolchain acceptance MUST include C++ LP64 EH link via HP ld (2026-07-23)
gas 2.46.1 built+smoked fine (C both ABIs, assembled+ran) and even disassembly-A/B'd identical to
as 2.18 on C code — then its LP64 objects WITH EH/unwind sections made HP ld B.12.34 segfault at
link time, discovered only after a full 3.4h gcc bootstrap's final smoke. Toolchain component
smokes must exercise the FULL flag surface of the real consumers: for an assembler on ia64-hpux
that means at minimum {C, C++-with-exceptions} × {ILP32, LP64}, each assemble→link-with-HP-ld→RUN.
"Assembles and runs hello-world both ABIs" is NOT acceptance.

## ncurses headers live in a SUBDIR — you need BOTH -I paths (2026-07-27, building nano)
ncurses 6.5 wide (`GNUtools.ncurses`) installs its headers as `/opt/gnu/include/ncursesw/curses.h`,
and that `curses.h` (line 90) does `#include <ncursesw/ncurses_dll.h>` — it resolves its own
siblings relative to the **parent** include dir. So `-I/opt/gnu/include/ncursesw` ALONE fails on the
first source file with `fatal error: ncursesw/ncurses_dll.h: No such file or directory`, and it
fails LATE: configure happily reports ncursesw found and sets `CURSES_LIB='-L/opt/gnu/lib
-lncursesw'` first. **Always pass both: `-I/opt/gnu/include/ncursesw -I/opt/gnu/include`.**
For autoconf packages using `PKG_CHECK_MODULES([NCURSESW],[ncursesw])` there is no `ncursesw.pc` on
this box, but presetting `NCURSESW_CFLAGS`/`NCURSESW_LIBS` makes the macro skip pkg-config entirely.

## libgnushim is MULTILIB — pick the right one or you get a bogus "compiler cannot create executables"
There are two: `/opt/gnu/lib/libgnushim.a` is **ELF-32 (ILP32)** and `/opt/gnu/lib/hpux64/libgnushim.a`
is **ELF-64 (LP64)**. Since the default build policy is LP64 (`-mlp64`), `-L/opt/gnu/lib -lgnushim`
links the WRONG ABI and configure dies at the trivial conftest with
`configure: error: C compiler cannot create executables` — which reads like a broken compiler and
sends you diagnosing the wrong thing (the compiler itself links fine by hand). **LP64 builds must use
`-L/opt/gnu/lib/hpux64 -lgnushim`.** Note the layout is NOT uniform: ncurses puts its LP64
`libncursesw.a` in `/opt/gnu/lib` itself, while `hpux64/` currently holds only libgnushim. Check with
`ar x` + `file` on a member rather than assuming from the path.

## HP-UX headers squat on short ALL-CAPS names — `REVISION` in <langinfo.h> (2026-07-27, nano)
`/usr/include/langinfo.h` has `#define REVISION 64` (an obsolete `nl_langinfo` item code). nano uses
`#ifdef REVISION` to mean "git build, REVISION is the commit string", so including `<langinfo.h>`
silently switches on that branch and `version()` does `printf("%s", 64)` → **Memory fault** on the
first `--version`. It COMPILES AND LINKS CLEANLY; the only hint is a `-Wformat` warning
("argument 2 has type 'int'") buried in the build log. Fix: `#undef REVISION` right after the
include, guarded by `__hpux`. **Generalise: when a package dies at runtime but built clean on this
box, grep the build log for `-Wformat` first — and suspect a system header defining a common
short macro (REVISION, ALIGN, PAGESIZE, MIN/MAX…) that the package uses as its own feature flag.**

## An interactive curses program cannot be acceptance-tested from a non-interactive ssh
`nano --version`/`--help` prove linkage, not rendering. Driving a full-screen curses app by piping
keystrokes into `ssh -tt` does NOT work reliably (tried twice: nano starts and stays alive under the
pty — which does prove `initscr()` succeeded — but the injected `^O`/`^X` never took effect, leaving
a stray process on a pty). There is no `expect` on the box. So: verify what can be verified
(ELF-64, `--version`, `--help`, `chatr` linkage, terminfo DB present) and hand the interactive smoke
test to Hugo rather than burning time on blind keystroke injection. Kill strays afterwards —
`pkill -f <path>` — or they sit on a pty forever.

## `--with-ld=X` does NOT make gcc link its OWN binaries with X (2026-07-31, cost a whole investigation)
`--with-ld=/opt/hld/bin/hld` sets `DEFAULT_LINKER` — the linker the **compiler you are building**
invokes when it links **target** programs. `cc1`, `cc1plus`, `lto1` and `xgcc` are **host** programs:
they are linked by the host `g++`, which uses ITS OWN compiled-in linker. Check it with
`g++ -print-prog-name=ld`, not with the configure log.

This cost days on the gcc 9.5 port: every cc1plus we dissected was HP `ld` output while we believed
it was our own linker's, so a bogus `br.call` past `_etext` and an `LTOFF22X`/`LDXMOV` theory were
both filed as linker defects against the wrong linker, plus four negative isolation tests chasing a
bug that was not there.

**To link the host binaries with a different linker, no makefile edits needed:**
```sh
mkdir -p /var/tmp/hldbin && ln -sf /opt/hld/bin/hld /var/tmp/hldbin/ld
export COMPILER_PATH=/var/tmp/hldbin      # gcc searches this for `ld` before its built-in path
g++ -print-prog-name=ld                   # MUST now report /var/tmp/hldbin/ld
```
`-B/var/tmp/hldbin/` works identically if you can reach the compiler's command line.

**Generalise — never diagnose a binary whose provenance you have not verified.** Get the producing
tool to stamp its output (hld ≥0.9.3 writes a `what` string) and check it FIRST. And beware
grep decoys when confirming which tool ran: our build log matched "hld" 2187 times but the actual
binary path `/opt/hld/bin/hld` only twice — 2058 matches were the SOURCE DIRECTORY, named
`gcc-9.5.0-hld`. Count the specific path, not the substring.

## `-lfoo` prefers the shared library — force static for gmp/mpfr/mpc (2026-07-31)
`/usr/local/ia64/lib/hpux64` holds both `libmpfr.a` and `libmpfr.so.4.1`, and `-lmpfr` takes the
`.so`. The resulting cc1plus then needs `SHLIB_PATH` set by the END USER to start, because
`libmpc.so.2`'s own RUNPATH points at `/usr/local/ia64/lib` — the **ILP32** dir — and `DT_RUNPATH`
is deliberately NOT inherited by dependencies, so the executable's correct RUNPATH does not rescue
its dependency's dependency. Symptom: `dld.so: Unable to find library 'libmpfr.so.4'`.

Fix, and what gcc upstream recommends anyway — a `-L` directory holding ONLY the archives, placed
before the real one:
```sh
M=/var/tmp/staticmath; mkdir -p $M
for l in mpc mpfr gmp; do ln -sf /usr/local/ia64/lib/hpux64/lib$l.a $M/lib$l.a; done
# then: -L$M -L/usr/local/ia64/lib/hpux64 -lmpc -lmpfr -lgmp
```
`DT_NEEDED` drops to `libc.so.1` alone and the binary runs with no `SHLIB_PATH`. Verify with
`readelf -d <binary> | grep -E 'NEEDED|RUNPATH'` — and prefer this over exporting `SHLIB_PATH`,
which merely hides the problem until someone else runs the compiler.

## `gcc` and `g++` are SEPARATE binaries with SEPARATE compiled-in specs (2026-07-31)
Changing a spec macro in `gcc/config/<cpu>/<os>.h` (LIB_SPEC, LINK_SPEC…) and relinking only `xgcc`
leaves the C++ driver carrying the OLD spec. The symptom is maddening: `gcc -dumpspecs` shows the
fix, `g++ -dumpspecs` does not, and every C++ link keeps failing exactly as before — so it looks
like the edit never took effect at all.

**Relink `xgcc xg++ cpp` together**, and verify with `-dumpspecs` on EACH driver, not just one.

Two more traps in the same area:
- **An objdir `gcc/specs` FILE overrides the built-in specs.** After editing a spec macro the driver
  can still emit the old link line because it is reading that file. Move it aside to test. The
  INSTALLED compiler has no specs file, which is why only a staged/installed test is trustworthy.
- **Editing any target header invalidates `tm.h`,** which most of the compiler includes — expect a
  ~450-object rebuild, not a relink. On a 1-CPU box that is ~40 minutes, so batch spec changes.

## Never acceptance-test an UNINSTALLED gcc from its objdir (2026-07-31)
`./gcc/xgcc -B./gcc/ -x c++ test.cc` fails with `fatal error: string: No such file or directory` —
an uninstalled driver has no libstdc++ header path. That is a HARNESS bug, not a compiler fault, and
it wasted a full build cycle. Install to a DESTDIR staging tree and test the staged compiler: gcc's
driver computes its paths relative to its own binary, so a staged tree runs in place. It also tests
what you would actually ship.

## HP-UX errno numbering diverges from Linux — `ENOSYS` is **251**, not 38 (2026-07-31)
Reported by the ia64-emulator session, measured against rx2620. The low values agree; the numbering
diverges above them. Anything that hard-codes an errno integer, or compares errno constants across
the two systems, is a trap — including compat shims that define a fallback when a symbol is missing.
Always use the `<errno.h>` constant, never the literal, and never copy an errno table from a Linux
man page into HP-UX code.

Related, from the same source and worth knowing when writing raw syscall probes on this box:
- **A symbol in a library does not mean the syscall exists.** `uld.so` ships a `_lwp_getprivate`
  stub, but syscall 67 is not in this kernel's table and the raw call takes SIGSYS.
- **Let a probe fault to discover arity.** `lwp_getscheduler` probed with 3 args writes the policy
  into arg 3 and *then* returns EFAULT for the missing 4th — the partial write reveals both the
  count and the order.
- **The assembler is a free oracle.** Deliberately assembling an illegal spelling makes `as` state
  the rule: `Operand 3 of 'fetchadd4.acq' should be an increment (+/- 1, 4, 8, or 16)`. Cheaper than
  reasoning about field widths.

## ⚠️ gas SILENTLY DISCARDS every `;;` unless the file says `.explicit` (2026-07-31)
Assembling any `.s` for ia64 without `.explicit` puts gas in auto-bundling mode, where it emits:

    Warning: Explicit stops are ignored in auto mode

and drops every stop bit you wrote. It is a WARNING, not an error — the object assembles,
disassembles, and looks right. For anything where a stop is semantically load-bearing (RSE work:
`mov ar.bspstore` then reading stacked registers; any `mov` to an application register followed by
a dependent read) the result is a program that measures or does the wrong thing with no diagnostic.

**Put `.explicit` as the first directive in every hand-written `.s`, and CONFIRM the stops survived
by disassembling the object** — `objdump -d x.o` should show `;;` where you wrote them. Checking
the disassembly is the positive control; assembling without error is not.

Not a concern for a file with no `;;` at all (e.g. a flat list of mnemonics used to pin encodings),
since auto mode only touches bundling and stops, not the 41-bit slot values.

## The generalisation behind four different silent-wrong-answer bugs (2026-07-31)
**A check is worthless when the check and the mechanism it is checking travel the same code path.**
Four routes to it, all hit in one day across this project and the emulator:
- **constant folding** — gcc proved the test's subjects were constants and stored the literal
  answer; the test reported a perfect score without executing the mechanism
- **the compiler relocating the subject** — `setjmp`'s `returns_twice` spills locals to the memory
  stack, so a test of register-stack restoration examined memory the rewind never touches
- **a shared helper** — spill, fill, `br.call` and `br.ret` all indexed the register file through
  one function, so they agreed with each other for ANY wrong value
- **documented into silence** — a crosscheck compared only the destination register because a
  comment asserted the other fields "aren't in the operand text". They were. The wrong belief was
  written down twice and went unexamined for 22,170 samples.
- **the instrument did not cover the hot path** — a per-phase profiler reported nothing useful
  because every phase was instrumented but the time was in the input loop that runs *before* the
  first phase. The measurement was real, the coverage was not. Ask what the instrument CANNOT see
  before trusting a null result from it.
**Actionable form: for any test, ask which code path the EXPECTATION came down.** If it is the same
one as the result, the test cannot fail. And when a tool reports success, check its denominator —
"0 unknown of 17,376 slots" was a real result from walking only `.text` in a C++ archive whose code
all lives in `.text._ZN...` COMDATs; the true figure was 146 of 215,558.

## Writing IA-64 assembly that touches the RSE — three rules, each learned by a fault (2026-08-01)
Found by RUNNING a hand-written `ar.bspstore` probe on rx2620; none is visible to gas, and the
first two fault rather than misbehave. Alongside the `.explicit` rule above, this is the checklist
for any `.s` that manipulates the register stack.

1. **`ar.bspstore` and `ar.rnat` may only be ACCESSED — read *or* written — with the RSE in
   enforced lazy mode** (`ar.rsc.mode == 0`). Merely *reading* `ar.bspstore` with the RSE running
   is an Illegal Operation fault (`ILL_ILLOPC`). Every access must sit inside a lazy-mode window,
   including a read before you have set anything and a read on the way out.
2. **Enforced lazy means clearing `rsc.MODE` (bits 1:0) ONLY — not writing `r0`.** `mov ar.rsc = r0`
   also zeroes `rsc.pl`, which tells the RSE to issue its loads and stores at privilege level 0;
   from a user process that faults the moment the RSE next runs. Use `and rX = -4, rSAVED`.
   HP's own `___longjmp` does exactly this (`and r27 = -4, r24`) — the answer was sitting in a
   disassembly we had already read, which is the reusable lesson: when unsure how to drive a
   platform mechanism, disassemble the vendor routine that already does it.
3. **A routine that rewinds `ar.bspstore` and then RETURNS must put it back — and `ar.rnat` with
   it.** Otherwise `br.ret` refills the caller's frame from wherever the anchor now points; the
   caller returns with a garbage `b0`. `longjmp` gets away with a rewind only because it rewinds to
   the frame it is actually returning *into*. A probe that returns normally must restore what it
   moved.

Also: **stay in lazy mode across the whole window.** Re-enabling the RSE between a rewind and the
reads lets it spill eagerly through the rewound anchor — `SEGV_MAPERR`. Reading GRs and storing to
memory need no RSE, so there is nothing to re-enable it for.

## Emulator-vs-box output diffs: `%llx` is a known false positive (2026-08-01)
Under the ia64-emulator only, HP's printf renders `%llx` as if `#` were set — `0x123456789a` where
rx2620 prints `123456789a`. Same for `%llX` and `%llo`. `%llu`, `%lld`, `%lx`, `%x` and `%p` are
identical. Pre-existing and localised to the conversion routine. If you ever diff a build's output
between the box and the emulator, do not chase a leading `0x` on a long-long hex conversion.

## `readelf -s` prints `.dynsym` and `.symtab` back to back with NO blank line (2026-08-01)
So the natural `sed '/dynsym/,/^$/p'` to isolate the dynamic symbols runs to EOF and silently
sweeps up `.symtab` as well. `.symtab` legitimately still lists names that `.dynsym` does not
export, so the result is a symbol list that looks like a leak and is not. Reported by the linker
session, which caught it before believing it — their export test had "found" 8 leaked symbols.

Use a range that ends at the next table, not at a blank line:

```sh
readelf -s lib.so | awk '/\.dynsym/{d=1} /\.symtab/{d=0} d'
```

Generalises: **before parsing any tool's output with a blank-line delimiter, check the tool
actually emits one.** This is the same family as walking only `.text` in a C++ archive whose code
lives in COMDATs, and as instrumenting every phase when the time is in the loop before them — the
instrument's coverage was not what its author believed.

## Verifying a "pure speedup": compare BEHAVIOUR, not just the artifact (2026-08-01)
When a change is argued to be output-neutral, comparing the produced file is the weak check and
comparing what that file *does* is the strong one. The linker session's stub-search reorder is the
worked example: reordering which of several equally-reachable stubs a branch is given cannot change
the stub *set*, only the assignment — a good argument, and good arguments have been wrong here
before. What they actually did:

1. same stub count from both builds — **13,142**, and independently confirmed by this session with
   a different method (`objdump -d | grep -c 'brl\.'`) from a different session
2. same image size — 96,275,304 bytes
3. ★ **both resulting cc1plus binaries compiled the same C++ TU to byte-identical object code**

Only (3) settles it. (1) and (2) say the artifact looks the same; (3) says it behaves the same.
For a compiler or linker the behavioural check is cheap — build something with both and `cmp` the
output — and it is the difference between "the bytes match" and "it still works".

Related: an earlier `qsort`-for-insertion-sort swap in the same session was verified the same way,
which matters because insertion sort is stable and qsort is not, so "same set" did not imply
"same order" and the order was observable.

## "Both implementations fail" is NOT evidence of a common cause (2026-08-01)
The cheapest way to misread a control. A reproducer was run through two linkers, both produced a
faulting shared library, and the conclusion drawn was "the platform/relocation is at fault, not the
new linker". Wrong: they failed for **two unrelated reasons** that happened to share a symptom class.

What went wrong is worth stating precisely, because the control itself looked textbook — it varied
exactly one thing, the linker:

- the **test case** varied two mechanisms at once. The failing function both went through `gp` AND
  reached `.rodata`, so a failure could not say which.
- the **compiler choice** silently added a third variable. Built with gcc 9.5, which emits
  `GPREL64I`, both libraries carried a relocation the vendor linker is *separately* documented to
  mishandle. Rebuilding with gcc 4.7.4 — which emits `LTOFF22X` and never `GPREL64I` — separated
  them, and the vendor linker then **passed**.

**The fix is to vary one thing in the TEST CASE too, not just in the tool.** Split the failing
function into the smallest independent exports — one touching no `gp`, one reaching `.sdata`, one
reaching `.rodata` — and the mechanism names itself. That is what identified the real defect
(a missing load-time relocation for a same-module data address) and simultaneously disproved the
"wrong GP" theory, since the `.sdata` case passed.

Corollary for reporting: when two implementations fail the same way, **ask what would have to be
true for that to be one bug**, and test it. Coincidence is common when the symptom is "SIGSEGV".

**And the positive form, which is the one that would have caught this a day earlier: when a test
splits into pass and fail, THE DIFFERENCE BETWEEN THE TWO CASES IS THE FINDING — name it explicitly
before drawing any conclusion from either side.** A split ran `.sdata` (passed) against `.rodata`
(failed) and both sessions read it as "gp is correct", in bold, and moved on. The true sentence was
one qualifier longer — *gp is correct for targets in gp's own segment* — and that qualifier was the
entire finding: on this platform the text and data segments load independently, so a gp-relative
constant reaching text is wrong the moment a shared library loads. Both of us named the mechanism we
were testing FOR and not the one that actually separated the two cases.

Practical form: after any pass/fail split, write down every property in which the two cases differ
BEFORE interpreting either. If more than one differs, the test has not isolated anything yet.

## Spec `-L` paths shadow the build's own `-L` — put them in the startfile prefixes instead (2026-08-02)

Patch 05c hardcodes `-L/usr/lib/hpux64 -L/lib/hpux64 -L/usr/ccs/lib/hpux64` into `LINK_SPEC`,
because `--disable-multilib` (forced by the LP64-only build) deletes the multilib machinery that
normally supplies them, leaving the driver unable to find `libc`. That patch is necessary and it
works — but it puts those paths **ahead of every `-L` the build itself passes**, and that caused a
second bug months later: gcc 9.5's stage2 `cc1` link resolved `-lz` to HP's zlib 1.2.3 in
`/usr/lib/hpux64` instead of gcc's own bundled 1.2.11, and died on `undefined symbol gzopen64`.

The ordering is structural, from `LINK_COMMAND_SPEC` (gcc.c:1036):

```
... %l ... %{!nostartfiles:%S} ... %@{L*} %(mfwrap) %(link_libgcc) ... %o ...
     ^LINK_SPEC                      ^cmdline -L    ^= "%D" = -L per startfile prefix
```

`%l` expands **before** the command-line `-L`; `%D` expands **after** it (`%D` emits `-L`, gcc.c:5388).
So no rearrangement *inside* `LINK_SPEC` can help — but the same paths carried in the **startfile
prefix list** land after the build's own `-L` and stop shadowing it.

**Measured 2026-08-02** with a decoy `libz.a` defining `gzopen64` (the system 1.2.3 does not, so
whichever `-L` wins is visible as a hard link success or failure):

| paths supplied via | cmdline `-L` | LP64 paths | outcome |
|---|---|---|---|
| `LINK_SPEC` (05c today) | pos 14 | pos 6–8 | `undefined symbol gzopen64` |
| startfile prefixes (`-B`) | pos 11 | pos 12–14 | links, runs, exit 0 |
| `LIBRARY_PATH` env | pos 11 | pos 14–16 | links, runs, exit 0 |

Controls under the fix: `libc`+`libm`, C++ exceptions (so `libunwind` resolves), and the
`/usr/lib/hpux64/unix98.o` startfile all still work.

**Two traps found while testing this:**

- **`startfile_prefix_spec` cannot be overridden with `-specs=`.** The driver consumes it at
  gcc.c:7677 but reads user spec files at gcc.c:7738 — 61 lines too late. A `-specs=` file setting
  it produces a `%D` list byte-identical to baseline, i.e. the experiment silently tests nothing.
  Use `-B` to exercise the same list from the command line; it feeds `startfile_prefixes` too.
- **`STARTFILE_PREFIX_SPEC` REPLACES rather than appends.** It is the `if` of an if/else, so
  defining it skips `MD_STARTFILE_PREFIX`, `MD_STARTFILE_PREFIX_1` and the standard prefixes
  (gcc.c:7689). gcc's own `lib/gcc/...` prefixes are added earlier (gcc.c:4229–4715) and do survive,
  so `-lgcc` is safe — but `/usr/ccs/lib/` would have to be re-listed by hand.

**Therefore the better vehicle on ia64-hpux is `MD_STARTFILE_PREFIX_1`, which this target leaves
unused** — it appends, with no replace semantics:

```c
#undef  MD_STARTFILE_PREFIX
#define MD_STARTFILE_PREFIX   "/usr/lib/hpux64/"       /* LP64 libc/libm/libunwind, unix98.o */
#undef  MD_STARTFILE_PREFIX_1
#define MD_STARTFILE_PREFIX_1 "/usr/ccs/lib/hpux64/"   /* crt0.o, lddstub */
```

and delete the three `-L` from `LINK_SPEC`. Note `/lib` is a symlink to `/usr/lib`, so 05c's
`-L/lib/hpux64` is **redundant** — it names the same directory as `-L/usr/lib/hpux64`.

Not applied yet: 05c as written is proven and a bootstrap depends on it. This replaces 05c's `-L`
block *and* the `gcc/Makefile.in` `ZLIB` patch with one smaller change, so it belongs at the start
of the next gcc build, not in the middle of a running one.

## `ps` truncation silently disables the "discard truncated objects" step in stop scripts (2026-08-02)

Stop scripts for long builds capture the in-flight compilers' `-o` arguments before killing, so the
objects they were mid-write can be deleted — otherwise `make` sees a truncated `.o` newer than its
source on resume and links it, which is a silent wrong answer rather than an error.

That capture does not work on HP-UX. `ps` truncates command lines, and a gcc driver line is long
enough that `-o <target>` falls past the cut, so `sed -n 's/.* -o \([^ ]*\).*/\1/p'` yields **nothing**
and the cleanup loop runs zero times while reporting success. Observed 2026-08-02: a live `cc1` was
captured in the snapshot, and the in-flight list still came out empty.

Do not depend on it. Either bound the risk structurally — stop only where little is in flight, then
verify (`find <current stage dir> -name '*.o' | wc -l`) — or drive cleanup from a `find ... -newer
<reference file>` created before the kill, since HP-UX `find` has **no `-mmin` and no `-newermt``**.
Related: the same missing predicates made an earlier stop script's cleanup a no-op for two weeks.

## Superseding a VENDOR product: the revision must match HP's SHAPE, not our convention (2026-08-02)

To replace an HP-shipped product rather than collide with it, an SD depot must reuse the vendor's
**product tag and fileset tags**, and offer a revision that compares **greater**. Reusing the fileset
tags is what makes it a supersede rather than an overlay: on update, files the old fileset had and
the new one does not are removed.

The trap is the revision string. Our house convention is `<upstream>-hh<n>`, but SD-UX compares
revisions field by field, so against HP's `A.07.00-1.2.3.001` a revision of `1.3.2-hh1` compares
**LESS** — `'1' < 'A'` in the very first field — and swinstall would refuse it as a downgrade.
Keep the vendor's shape and bump a leading field instead: `A.07.00-1.2.3.001` → `A.08.00-1.3.2.001`.
Put our identity in the `vendor` tag and the titles, where it does not affect ordering.

Worked example: `Zlib` 1.3.2 (2026-08-02), filesets ZLIB-LIB/-INC/-DOC/-MAN/-SRC mirrored from HP's.
Check what you are superseding first — `swlist -l product -a revision <Tag>` and
`swlist -l file <Tag>` — because the file list tells you what will be REMOVED if you do not ship it.

Related trap, same session: **`cp -p` from the NFS share fails on rx2620** with
`cp: preserving permissions ...: Not owner`. The share's files are owned by the dev box's uid 1001
and the box runs as uid 106, so the mode-preserving copy is denied. Use plain `cp` plus an explicit
`chmod` for anything sourced from `/mnt/debianshare`; `-p` is fine for files already local to /var/tmp.

## zlib on HP-UX 11.23 needs -DHAVE_VSNPRINTF or gzprintf() silently becomes a stub (2026-08-02)

`gzguts.h` reasons "if C89/90, assume no C99 snprintf()/vsnprintf()" and keys that on
`__STDC_VERSION__`, which gcc leaves undefined in its default `gnu89` mode. zlib then compiles
`gzvprintf()` as `return Z_STREAM_ERROR` — a permanently broken `gzprintf()` in an otherwise
perfect-looking library. Its own configure had already proven the real `vsnprintf` works here
("Checking for vsnprintf() in stdio.h... Yes"), so the assumption is simply wrong on this platform.

Only zlib's **self-test** catches it (`gzprintf err:` then `*** zlib test FAILED ***`) — which is the
argument for gating on `make test` in general. The fix is a configure-line `-DHAVE_VSNPRINTF`
(the documented escape at `gzguts.h:80`), not a patch. Also pass `CFLAGS` explicitly for a second
reason: zlib's configure defaults to `-O3`, and -O3 is cursed on this box's ia64.

## hld and SHARED libraries — WORKING as of 0.9.17 (2026-08-02); 0.9.10 and earlier are NOT

**hld ≥ 0.9.17 builds correct shared libraries**: zlib 1.3.2 passes all three of its own suites
(`test`, `shared test`, `64-bit test`) built entirely by hld. Anything at **0.9.10 or earlier
silently produces broken `.so` files** — use HP `ld` with those. hld has always been fine for
executables, and is irrelevant to static archives (`ar`, no linker involved). One gap remains: hld
refuses **undefined symbols in a `.so`**, where HP `ld` correctly defers them to load time, so plain
`gcc -shared` fails (ia64-hpux `LIB_SPEC` is `%{!shared:...}`-guarded, so the driver passes no
`-lc`). Workaround, one line: `LDSHARED="gcc -mlp64 -shared -Wl,+h,libfoo.so.1 -lc"`.

Six defects were found and fixed in one evening, 0.9.10 → 0.9.17. **Four of them needed a real
library; two of those hid behind a fixture that passed.** The generalisation worth keeping: *a
fixture is a hypothesis about which dimensions matter, and it is exactly as good as that hypothesis.*
Both fixtures that fooled us were simpler than the real thing in the one dimension that turned out
to be load-bearing — one filename, one slot boundary.

Reproducers on the share, all taking the hld binary as `$1`, all seconds:
`verify_hld_0911.sh` (full battery incl. a zlib build), `hld_reloc_repro.sh` (pointer tables),
`iplt_repro.sh` (import descriptors), `struct_fptr_repro.sh` (struct-member pointers),
`fnaddr_repro.sh` (address-taken-in-code), `zlib_stage_probe.sh` (which zlib call faults).
**A test linker needs no depot and no install** — copy it to /var/tmp, symlink it as `ld` in a
private dir, point `COMPILER_PATH` there. That is how all of this was measured; the installed
`/opt/hld/bin/hld` was never touched.

**Expect hld to emit ~35 fewer relocations than HP ld and do not read that as a defect.** On zlib:
HP 172, hld 137, and the entire difference is import descriptors — 51 vs 16, because HP emits
roughly one per *call site* and hld one per *distinct imported symbol*. Both run. Everything that
should match does, to the unit: 116 data pointers each, 5 descriptors each, 95 exported symbols
each, 17 distinct imports each. (hld expresses as anchored `DIR64` what HP splits between `DIR64`
and `REL64`.)

**Two dead ends worth not repeating — both looked like the obvious culprit, neither was.**

*Missing `DT_JMPREL`/`DT_PLTREL`/`DT_PLTRELSZ`* is a deliberate design choice (relocations advertised
once via `DT_RELA`); a one-function `.so` calling `strlen` runs correctly under hld without them.

*The `R_IA64_IPLTMSB` count — hld 17 vs HP 51 on zlib, unmoved across three releases while
everything around it changed* — is correct by design. hld emits one import descriptor per **distinct
imported symbol**, HP roughly one per **call site**: measured at 1/4/17 descriptors against 1/4/17
distinct symbols, and **both reproducers run correctly**, so one-per-symbol is sufficient. A number
that does not move while everything around it changes is worth flagging — but it is also exactly
what a correct invariant looks like.

**Method note that saved this from being nonsense:** the first version of the libc-call reproducer
set `+h libslib.so` while the files were named `libslib.<linker>.so`, so both consumers died in
`dld.so: Unable to find library` before executing anything — which reads as "both linkers fail".
When a SONAME and a filename disagree, nothing runs and the test measures nothing.

## `-print-prog-name` is a CLAIM; `-Wl,-V` is the measurement (2026-08-03)

Verified on-box, and it decides whether any "we tested linker X" statement is worth anything:

| driver | `-print-prog-name=ld` | what `-Wl,-V` shows actually ran |
|---|---|---|
| gcc 4.7.4 (no `--with-ld`) + `COMPILER_PATH` | `/var/tmp/vtest/ld` | **hld 0.9.14** — genuinely redirected |
| gcc 9.5 (`--with-ld=/opt/hld/bin/hld`) | the `-B` path | **the INSTALLED linker** — redirect ignored |

**gcc 9.5's absolute `DEFAULT_LINKER` cannot be overridden by `-B`, by `COMPILER_PATH`, or by naming
the file `hld` in a `-B` directory.** All three were tried. The trap is that `-print-prog-name`
happily returns the `-B` path in every case, so a candidate linker reads as tested when it was never
loaded, and the result is a clean-looking measurement of the wrong binary.

**Rule: assert linker identity with `-Wl,-V`, never with `-print-prog-name`.** hld stamps its version
there precisely so this is checkable. Testing an unreleased hld through gcc 9.5 requires installing
it (root) or driving it directly on `.o` files — there is no override.

This is the same family as the week lost analysing HP `ld` output believing it was hld's, and it is
worth being blunt about why it keeps recurring: **every one of these traps is a check that returns a
plausible answer without measuring the thing it appears to measure.** `-print-prog-name` reports a
lookup, not an execution. `swlist` reports what SD installed, not what is on disk. A fixture reports
its own dimensions, not the real workload's. Prefer the observation that could only be true if the
thing actually happened.

Related, same target: **`gcc -rdynamic` fails in the DRIVER** on `ia64-hp-hpux11.23` — the spec has
no `-rdynamic`, so it never reaches the linker. hld accepts it (0.9.18+) but only `-Wl,-E` /
`-Wl,--export-dynamic` can exercise that through gcc. A configure script probing `$CC -rdynamic` and
getting a rejection is behaving correctly; it is not an hld gap.

## `.note` version strings are a MERGE, not a producer stamp — and three ways to fail to read them (2026-08-03)

HP ld records a `92453-07 linker ld HP Itanium(R) B.12.NN` string in **`.note`**, with **no `@(#)`
prefix**. Two consequences, both of which cost time on the same file within an hour:

**1. It does not identify who linked the file.** It is inherited from input objects *and* appended by
the linker that ran, so one binary carries several. Measured:
```
crt0.o        B.12.35        libc.so.1     B.12.11        libunwind.so  B.12.43
a fresh HP-ld link with crt0.o  ->  B.12.35 AND B.12.42   (inherited + the ld that ran)
```
⇒ **Never infer provenance from a `.note` version.** Use `what` (the `@(#)` stamp, which a producer
writes deliberately) or `-Wl,-V` for linkers. `.note` answers "what went into this", not "who made it".

**The concrete producer stamp for linkers lives in `.comment` (confirmed 2026-08-10):**
| linker | `.comment` holds | `what <binary>` |
|---|---|---|
| hld | `@(#)hld 0.11.2 - LP64 linker for HP-UX 11.23/IPF` | prints it, **with the version** |
| HP ld | the input objects' `GCC: (GNU) 4.7.4`, concatenated | nothing |

This is the only provenance check that works on a **finished artifact** — a depot you did not build,
a binary from last month — with no build log. It also works **off-box**: the dev box's `readelf -p
.comment` / `strings` read HP-UX ia64 binaries fine, so a depot can be audited without booting
rx2620. Gate packaging on it: a build script that merely *prints* the linker it measured will ship an
HP-ld binary when a link silently falls back, which is exactly how `GNUfindutils 4.10.0-hh1` shipped.
Re-check after `make install` — a stripping install rule erases `.comment` and the provenance with it.

⚠️ **`-Wl,-V` is a QUERY: hld prints its version and EXITS WITHOUT LINKING.** No output file is
produced, so it cannot double as the artifact probe. A gate that links with `-Wl,-V` and then reads
the result's stamp inspects a file that does not exist and reports a false "not hld-linked". Two
probes: `-Wl,-V` for the version, a plain link for something to inspect.

**2. Three readers disagree on whether the string exists at all:**
| reader | result |
|---|---|
| `what` | **cannot see it** — no `@(#)` prefix |
| `/usr/bin/strings` (HP) | **0** by default; **1** with `-a` |
| GNU `strings` (binutils2461) | 1 |
| `readelf -p .note` | shows it plainly — **use this** |

**And the meta-trap, which is the transferable one:** my "0 hits" came from
`/opt/gnu/bin/strings <file> 2>/dev/null | grep -c` where **`/opt/gnu/bin/strings` does not exist**.
A missing binary plus discarded stderr plus `grep -c` yields a confident, plausible **0** — identical
to "the string is absent". `cmd 2>/dev/null | grep -c pattern` returns 0 both when the pattern is
missing and when `cmd` never ran. **Check the tool exists, or don't discard its stderr**, and prefer
`grep -c` only where you have separately confirmed the producer runs. Same family as everything else
in this file: a check that returns a plausible answer without measuring the thing it appears to.

## ⛔ NEVER put `-include <header>` in the CFLAGS you hand to a gnulib `configure` (2026-08-10)

It corrupts the build in a way that surfaces hundreds of lines later as an HP `/bin/sh` syntax error:

```
/bin/sh: Syntax error at line 1 : `}' is not expected.
gmake[5]: *** [Makefile:4179: libgnulib_a-access.o] Error 2
```

**Mechanism.** gnulib's `gl_CFLAG_GNULIB_WARNINGS` writes a `conftest.c` that is **not C** — it is a
list of `-Wno-*` flags wrapped in `#if` compiler-version guards — and uses the preprocessor purely to
filter that list, keeping every output line that does not begin with `#`:

```sh
gl_command="$CC $CFLAGS $CPPFLAGS -E conftest.c > conftest.out"
gl_options=`grep -v '#' conftest.out`
for word in $gl_options; do GL_CFLAG_GNULIB_WARNINGS="$GL_CFLAG_GNULIB_WARNINGS $word"; done
```

A force-included header makes `-E` emit all of its declarations — and every system header it drags
in — ahead of the flag list. None of those lines start with `#`, so all of them survive the filter
and become "flags". `GL_CFLAG_GNULIB_WARNINGS` is then substituted into **every** gnulib compile
line, and HP `/bin/sh` dies on the first `}` of the first struct.

The unquoted `for word in $gl_options` also **globs**, so `char *` expands against the build
directory. That is the tell in the generated Makefile — real filenames embedded mid-declaration:
```
extern int getopt(int, char cfg.log confdefs.h config.log conftest.c conftest.out const [], ...
```
Seeing your own build artifacts inside a C prototype means a shell loop consumed preprocessor output.

**Diagnosis, when the error names a `.o` and gives no useful context:** the recipe is identical to a
known-good build's, so the difference is in a variable. `gmake -n <the.o>` prints the expanded
command and the junk is unmissable; `grep '^GL_CFLAG_GNULIB_WARNINGS' Makefile` confirms it in one
line. Diffing the generated Makefile against a previous working objdir localises it fastest.

**Fix / general rule:** anything that makes `-E` emit content — `-include`, `-imacros` — belongs in
the *build*, never in the flags a gnulib configure sees. Better still, fix the underlying need
properly: the force-include here was guarding against implicit declarations, but only **one** existed
(`strtok_r`), and HP declares it correctly in `<string.h>` behind `#ifdef _REENTRANT`. **`-D_REENTRANT`
exposes the platform's own prototype** and costs nothing.

### The reason that one implicit declaration mattered: LP64 pointer truncation
`strtok_r` returns `char *`. Implicitly declared, it is typed `int`, and **LP64 truncates the
returned pointer to 32 bits** — the same failure that made htop die in `strchr` on `0x21d00`. The
crash lands nowhere near the cause, so catch it at compile time and treat it as fatal:

```sh
grep -c "implicit declaration of function" mk.log     # must be 0
grep -o "implicit declaration of function .[a-zA-Z_0-9]*" mk.log | sort -u
```

Any name in that list returning a pointer is a live LP64 bug. HP hides several reentrant prototypes
behind `_REENTRANT`, so look for the feature-test macro before writing a shim declaration.

## ⛔ Undefined WEAK symbols do NOT resolve to 0 — dld refuses the image at LOAD (2026-08-10)

Reported by the hld project session, verified there under **both** linkers. The optional-dependency
idiom that gnulib, glib and friends use freely:

```c
extern int maybe_absent(void) __attribute__((weak));
int probe(void) { return maybe_absent ? maybe_absent() : -7; }   /* expects 0 when unprovided */
```

```
hld    -> dld.so: Unsatisfied code symbol 'maybe_absent' in load module './libwu.so'
HP ld  -> dld.so: Unsatisfied code symbol 'maybe_absent' in load module './libwu.so'
```

**Both linkers accept it; the DYNAMIC LOADER rejects it.** So this is neither an hld gap nor
something `+noallowunsats` or any link flag changes — the symbol must actually be satisfied, or the
feature configured out of the package.

**Why it is expensive:** the build is clean and silent, and the failure appears only when the binary
is RUN, as `Unsatisfied code symbol` from dld. If a package built without complaint and dies at
startup that way, check for weak undefined symbols first. It also means a "successful build" gate
that never executes the artifact cannot catch it — one more reason every build here ends by running
the thing.

💡 Weak **defined** symbols are fine: a strong definition in the program overrides a weak one in a
library, identically under both linkers. Only *undefined* weak is broken.

Mitigation: static linking sidesteps it entirely (the symbol is resolved or the link fails loudly),
which is one more argument for `--disable-shared` on build-tooling like Tcl/Expect.
