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

## Archives / extraction — LARGELY OBSOLETE since 2026-07-20 (Hugo pointed this out)
> **GNU tar 1.35 + xz 5.4.7 + bzip2 1.0.8 ARE BUILT** (interim set, gcc 4.6.1). tar shells out to
> the compressor programs, so the box extracts `.tar.gz`/`.tar.bz2`/`.tar.xz` AND long-path
> (@LongLink) archives natively — put the staging bins on PATH:
> `/home/claude/build/interim/stage-{tar-1.35,xz-5.4.7,bzip2}/usr/local/ia64/bin` (works NOW, no
> swinstall needed; running from staging is a permitted build bridge). **Stop converting tarballs
> to .gz on the dev box.** The issues below only still apply to a BARE box (fresh
> install/pre-interim bootstrap) — delete this section once the interim depot is swinstalled.
- **HP `tar` cannot read GNU `@LongLink` long-path entries** (`tar: ././@LongLink - cannot create`).
  Any package with paths >100 chars (gcc, big trees) must be **extracted on the dev box** (GNU tar)
  into the share; build from the pre-extracted tree (out-of-tree build reads NFS source fine).
- **rx2620 has only `gunzip`** (`/usr/contrib/bin`), **no bzip2/xz**. Convert `.tar.bz2`/`.tar.xz` to
  `.tar.gz` on the dev box (`bunzip2 -c f | gzip -9 > f.gz`, `xz -dc f | gzip -9 > f.gz`) OR just
  extract on the dev box into the share. (Building GNU tar + bzip2/xz on the box removes this later.)

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
- **HP `/usr/bin/make` can't build GNU packages** — use our gmake (`/home/claude/build/make-4.4/make`;
  or build gmake first via its `build.sh`, which needs no pre-existing make). **GOTCHA: `build.sh`
  requires `./configure` to have run FIRST** (it reads the configure-generated `build.cfg`;
  otherwise instant `./build.cfg: not found`).
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
