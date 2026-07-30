# A modern GNU toolchain for HP-UX 11.23 on Itanium, bootstrapped from HP's own compiler

This is the source side of an effort to build a current GNU toolchain and userland on a
2004-vintage **HP Integrity rx2620** (HP-UX B.11.23, ia64) using **nothing but the compiler HP
shipped on the machine**. No third-party binaries are used anywhere in the chain.

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

## Layout

| path | what |
|---|---|
| `docs/gotchas.md` | **Read this first.** Every HP-UX 11.23 build failure hit here, with its cause and fix. |
| `docs/policy.md` | ABI (LP64 default), optimisation limits, acceptance rules. |
| `docs/packaging.md` | The `swpackage` PSF recipe and the SD-UX traps. |
| `patches/<tool>/<version>/` | Numbered patch series, one concern per patch, `patch -p1` from the source root. |
| `build/` | Per-tool build recipes: detached, sentinel-gated, with version ladders. |
| `packaging/` | Scripts that turn a staged tree into a depot. |
| `helpers/bin/` | Admin helpers shipped as the `HelperScripts` SD product. |

## Applying a patch series

```sh
tar xf nano-9.1.tar.gz
cd nano-9.1
for p in ../patches/nano/9.1/*.patch ; do patch -p1 -i "$p" || break ; done
```

Every patch in this repository has been verified to apply cleanly to the pristine upstream tarball.

## On the patches

They fall into three kinds, and the distinction matters:

- **Portability fixes** that are correct everywhere and are upstreamable as-is — e.g.
  `nano/9.1/0001`, which routes timestamp access through gnulib's `stat-time` module rather than
  raw `st_mtim`, because HP-UX 11.23 has no nanosecond stat timestamps at all.
- **Platform workarounds** that are right for this target and wrong elsewhere — e.g.
  `gcc/9.5.0/0001`, which stops using `@gprel64` for local symbols because HP `ld` mis-applies the
  relocation and corrupts the instruction bundle.
- **Diagnostics**, kept for the record, not for shipping — e.g. `gcc/9.5.0/0006`, the SIGSEGV
  handler that printed the ia64 fault context and showed `si_addr == ip`, which is how the
  out-of-range-branch problem was identified in the first place.

Each patch says which it is in its header.

## Related

`libgnushim` — the 17-function HP-UX 11.23 compat shim (gnulib-derived, pinned 2020) — is its own
repository. It is a real library with an API contract consumed by many of these builds, so it is
versioned independently rather than vendored here.

## Licence

The patches are derivative works of their upstream projects and carry those projects' licences
(GPL for gcc and nano). The build scripts, packaging recipes, helpers and documentation in this
repository are original work — see `LICENSE`.
