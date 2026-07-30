# Build & packaging policy (rx2620)

These are Hugo's standing preferences. Follow them unless he says otherwise for a specific build.

## Optimization
- **The compiler determines the flag** (Hugo 2026-07-18; REVISED 2026-07-19):
  - gcc **4.6.1 → `-O2`** (its `-O3` miscompiles on ia64 — a `-O3` m4 segfaulted at runtime).
  - gcc **4.8.5 → prefer `-O3` but with `-O2` fallback** — REVISED: 4.8.5's `-O3` is ALSO unreliable
    on ia64. Bootstrapping gcc at `BOOT_CFLAGS=-O3` ICE'd (`expand_shift_1 at expmed.c:2245` building
    optabs.c), so **build gcc itself at `-O2`**. For other packages `-O3` may work but can ICE on
    complex code — use the template's `-O3`→`-O2` fallback and let `make check` gate it, don't assume
    `-O3` is safe. When in doubt on ia64, `-O2` is the reliable level for ANY gcc here.
  - So `-O2`: GMP/MPFR/MPC, tar/bzip2/xz, gcc-4.8.5 **stage1**, and the initial stopgaps (gawk 3.1.8 +
    the first gmake). `-O3`: everything built by 4.8.5 — gmake rebuild, bash, autotools, gnulib,
    gawk 5.4.1 / grep / coreutils.
- **gcc 4.8.5 bootstrap** uses split flags: `STAGE1_CFLAGS=-O2` (stage1 built by 4.6.1) +
  `BOOT_CFLAGS=-O3` (stage2/3 built by the new 4.8.5).
- Still run `make check` as a correctness gate; never ship a build whose checks didn't pass. Report
  benign HP-UX/locale test failures rather than silently shipping or discarding.

## ABI (HP-UX ia64: ILP32 vs LP64)
- **REVISED 2026-07-20 (Hugo): ILP32 is BEST-EFFORT ONLY — never force it, never let it block.**
  LP64 is the required deliverable (32-bit-only Itaniums are vanishingly rare). Attempt ILP32 where
  cheap; if it fights back, ship LP64-only and note the omission. Read the "BOTH ABIs" items below
  through that lens: LP64 mandatory, ILP32 attempted.
- **Default LP64** (`-mlp64`) for all compilation. ILP32 = `-milp32`. The two CANNOT be mixed in one
  executable (ELFCLASS/calling-convention boundary), so an LP64 program links only LP64 libs.
- **Libraries** (GMP/MPFR/MPC, libgnu, …) → build AND `make check` in **BOTH** ABIs; install to the
  HP-UX multilib layout: LP64 → `lib/hpux64` + headers in `include/`; ILP32 → `lib/hpux32` + headers
  in `include/hpux32`. (gmp.h/mpfr.h are ABI-specific — separate the 32-bit headers.) Use MPFR/MPC's
  `--with-gmp-lib`/`--with-gmp-include` split flags to point at the right ABI dir + bake correct rpath.
- **Compiled executables** (gmake, gawk, grep, coreutils, gcc, m4) → build BOTH ABIs where possible,
  package both. **Architecture-independent tools** (autoconf, automake, libtool/libtoolize scripts)
  → ONE noarch depot (`machine_type *`); only the compiled parts (m4, libtool's libltdl) get both ABIs.
- Reuse note: the box already has LP64 GMP 5.x / MPFR 3.0.1 / MPC 0.8.2 under `/usr/local/ia64`
  (`gmp.h` is LP64; libs in `lib/hpux64`) — usable for an initial gcc 4.8.5 without rebuilding libs.

## Install / packaging
- **NEVER `make install` to the live system** (`/usr/local/ia64`) and NEVER `swinstall`. Hugo installs
  via the depot himself (he's root). Build scripts may only `make install DESTDIR=<private staging>`
  (e.g. `/home/claude/build/stage*`) to collect files for `swpackage`. Using a freshly-built tool
  from its build/staging dir as a build bridge (e.g. gawk on the build PATH) is fine.
- **Package EVERY toolchain build into a swinstallable SD depot** (not a bare install). Deliver the
  `.depot` into `/mnt/debianshare/own_depots/`.

## Full functionality
Configure for complete features, not minimal: enable relevant languages/bindings (e.g. GMP
`--enable-cxx`, gcc full language set), shared+static. Don't `--disable-*` to dodge a build problem
without flagging it.

## Sources
Pull from `https://ftp.gnu.org/gnu/<project>/` (mpc-0.8.x era predates GNU → gcc infra mirror).
Latest STABLE, not experimental/dev. Download on the dev box into `/mnt/nfs/gnu_tarballs/`.

## ABI ordering (Hugo 2026-07-23)
Build the LP64 variant FIRST (CC="gcc -mlp64"); it is the deliverable. Attempt ILP32 only after
LP64 fully succeeds, and abandon ILP32 without fighting if it misbehaves — LP64-only depots are
fine. Modern tool sources are untested as ILP32 host binaries (proven: gas ILP32-host relocation
corruption 2026-07-23) — prefer LP64 host binaries for everything we run on the box.
