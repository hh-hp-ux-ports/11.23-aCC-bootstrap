# gcc for HP-UX 11.23 on Itanium, bootstrapped from HP's own aC++

This is the source side of an effort to build a current GNU toolchain and userland on a
2004-vintage **HP Integrity rx2620** (HP-UX B.11.23, ia64) using **nothing but the compiler HP
shipped on the machine**. No third-party binaries are used anywhere in the chain.

**And as of 2026-08-04 that no longer means HP's licensed aC++.** The chain also starts from the
**bundled** compiler — `/usr/bin/cc`, *"HP aC++/C for Itanium B3910B A.05.50"* — which ships on
every 11.23 system and needs no codeword. That matters: it means anyone with a stock box can
reproduce this, not only someone holding an HP compiler licence. See
[the bootstrap pipeline](#bootstrapping-from-a-stock-box) below.

The build outputs are swinstallable SD-UX depots. They are **not in git** — they are attached to
tagged releases, because they run 40 MB to 350 MB each. What lives here is everything needed to
reproduce them: the patch series, the build recipes, the packaging recipes, and — most importantly —
the accumulated knowledge of what breaks on this platform and why.

## The provenance chain

```
HP aC++ (2003, on the machine)
   └─> gcc 3.4.6            C-only, the oldest gcc aC++ can still build
        └─> gcc 4.7.4       first modern C/C++ compiler in the chain
             └─> binutils 2.46.1      (LP64-hosted; ILP32-hosted gas has an r_offset bug)
                  └─> gcc 4.7.4 #2    rebuilt with the new binutils; stage2 == stage3
```

That second 4.7.4 is the shipping compiler, and it is the box's system compiler today. A second,
independently-built 4.7.4 exists via a different route, which lets the two be cross-validated
against each other.

gcc 9.5 builds and its `cc1`/`cc1plus`/`lto1` link — but only against a linker we built ourselves.
HP's `ld` B.12.34 emits 26 out-of-range direct `br.call`s in the 37.6 MB `cc1plus` instead of
long-branch stubs. See `patches/gcc/9.5.0/` and `docs/gotchas.md`.

## Bootstrapping from a stock box

The route above needs HP's *licensed* aC++. There is a second route that needs nothing licensed at
all, starting from the bundled `cc`. Measured on the box; each rung marks how far it is proven.

```
stock 11.23 + bundled cc                         (no codeword)
  └─ GNU make 4.3                                 built
      └─ hld            HP ld is used exactly ONCE in the whole chain — here
          └─ GMP 4.3.2 · MPFR 2.4.2 · MPC 0.8.1   built
              └─ binutils 2.35.2                  built (libiberty + libbfd)
                  └─ gcc 4.7.4                    configures; first objects compile
                      ├─ binutils 2.46.1  (LP64-hosted)
                      ├─ GMP 6.3.0 · MPFR 4.2.1 · MPC 1.3.1
                      ├─ zlib 1.3.2       (both ABIs)
                      └─ gcc 9.5.0        (patches 0001, 0002, 0004)
```

**gcc 3.4.6 drops out of this route.** The aCC chain needed it as a stepping stone; the bundled cc
configures and compiles gcc 4.7.4 directly, so the rung is unnecessary.

Three things decide whether this works, and all three are version or flag choices, not compiler
limits:

- **make 4.3, not 4.4.x.** 4.4.1 pulls modern gnulib, whose `findprog-in.c` uses C99 `<stdbool.h>`
  and stops with `Reserved word "bool" is not allowed in ANSI C`.
- **binutils 2.35.2, built with `-DPLUGIN_BIG_ENDIAN=1`.** 2.41 and later demand C99 at configure
  time and refuse this compiler. 2.35.2 accepts it, but `include/plugin-api.h` probes for compiler
  macros HP's `cc` does not define and hits `#error "Could not detect architecture endianess"`.
  That one define is the only blocker.
- **gcc 4.7.4 is the ceiling.** gcc 4.8 and later require a C++98 *host* compiler, which the bundled
  `cc` is not. 4.7.4 is plain C to build — and it is also the last gcc here with working ILP32
  codegen, so keep its multilib.

The bundled compiler handles ANSI prototypes, `const`, `long long`, `//` comments,
declaration-after-statement and variadic macros. It does **not** support the `inline` keyword or
`<stdint.h>`'s `int64_t`, and it *silently ignores* `-Ae` with a warning. autoconf probes for both
gaps and works around them, which is why era-appropriate versions matter more than the gaps do.

**What is not yet proven:** a complete gcc 4.7.4 build from the bundled `cc`. Configure succeeds and
the first objects compile; the rest is hours of machine time rather than an open question.

## Layout

| path | what |
|---|---|
| `docs/gotchas.md` | **Read this first.** Every HP-UX 11.23 build failure hit here, with its cause and fix. Canonical copy — the userland repo links to it rather than duplicating it. |
| `docs/policy.md` | ABI (LP64 default), optimisation limits, acceptance rules. |
| `docs/packaging.md` | The `swpackage` PSF recipe and the SD-UX traps. |
| `patches/gcc/<version>/` | Numbered patch series, one concern per patch, `patch -p1` from the source root. |
| `build/` | The compiler build recipes: detached, sentinel-gated. |

The GNU **userland** for this platform — nano, grep, the SD packaging and the admin helpers — lives
in [11.23-ports](https://github.com/hh-hp-ux-ports/11.23-ports). This repository is the compiler
chain only.

## Applying a patch series

```sh
tar xf gcc-9.5.0.tar.xz
cd gcc-9.5.0
for p in ../patches/gcc/9.5.0/*.patch ; do patch -p1 -i "$p" || break ; done
```

Every patch in this repository has been verified to apply cleanly to the pristine upstream tarball.

## On the patches

They fall into three kinds, and the distinction matters:

- **Portability fixes** that are correct everywhere — e.g. `gcc/9.5.0/0004`. HP-UX 11.23 **does**
  have `nftw()`; what differs is that it passes `struct FTW` to the callback **by value** where
  POSIX passes a pointer. (An earlier version of this patch, and of this README, claimed the
  function was missing. It is not — the signature differs.)
- **Platform workarounds** that are right for this target and wrong elsewhere — e.g.
  `gcc/9.5.0/0001`, which stops using `@gprel64` for local symbols. It has **two** independent
  justifications and the second is the load-bearing one: HP `ld` mis-applies the relocation and
  corrupts the instruction bundle, *and* — for **every** linker — a gp-relative constant encodes a
  link-time distance that ia64-hpux does not preserve, because the text and data segments are mapped
  independently. No linker can write a correct value there, so this patch is permanent for any build
  producing shared objects.
- **Diagnostics**, kept for the record, not for shipping — e.g. `gcc/9.5.0/0006`, the SIGSEGV
  handler that printed the ia64 fault context and showed `si_addr == ip`, which is how the
  out-of-range-branch problem was identified in the first place.

Each patch says which it is in its header.

## Related

- [11.23-ports](https://github.com/hh-hp-ux-ports/11.23-ports) — the GNU userland built with this
  compiler, plus the SD packaging and admin helpers.
- [11.23-libgnushim](https://github.com/hh-hp-ux-ports/11.23-libgnushim) — the 17-function HP-UX
  11.23 compat shim. A real library with an API contract, so versioned independently.
- [11.23-hld](https://github.com/hh-hp-ux-ports/11.23-hld) — a linker for this target. HP's `ld`
  mis-links binaries past PCREL21B's ±16 MB reach, which is what stalled gcc 9.5 here.

## Licence

The patches are derivative works of the packages they modify and carry those packages' licences —
which is what lets any of them go upstream unchanged. Everything present today patches GCC or
binutils, both GPL-3.0-or-later, so [LICENSE](LICENSE) governs them; read a patch's own header
rather than assuming that holds for a future one. The build recipes and documentation here are
original work, also GPL-3.0-or-later. See [COPYRIGHT](COPYRIGHT) for the full scope.
