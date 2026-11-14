# sssd

Rootless-capable SSSD built from the upstream release tarball, published to
`ghcr.io/malarinv/sssd`. Built on GitHub Actions (6h job budget) and consumed
as a base image.

## Why this exists

Debian trixie's `sssd` 2.10.1-2+b1 is compiled **without**
`--with-sssd-user=sssd`, and such a binary refuses to run unprivileged
outright. Verified directly, both sides of the comparison:

| Binary | Run as non-root | Result |
|---|---|---|
| Debian `sssd` 2.10.1-2+b1 | `uid 65534` | `Non-root service user support isn't built. Can't run under 65534:65534` |
| this image | `uid 999` | Past startup, into config loading |

It is a compile-time property — the guard is in `monitor.c` behind
`#ifndef SSSD_NON_ROOT_USER` — so capabilities, UID mapping and file ownership
cannot substitute for the flag. Hence the source build.

The security payoff: SSSD's **LDAP back end** — the component that parses
attacker-influenceable directory data — runs as `sssd` rather than root. The
monitor still runs root (it spawns/supervises responders and authenticates
privileged D-Bus requests), which is why the consuming pod keeps
SETUID/SETGID/CHOWN. That is the accepted posture, not an oversight.

## Why it is built here and not in the samba repo

It used to be stage 1 of the `malarinv/samba` image. Combined, that build takes
~48 min and exceeds the Forgejo runner's 60-minute cap. The runner is a KEDA
ScaledJob with `activeDeadlineSeconds: 3600`; two builds died with

```
status: Failed, reason: DeadlineExceeded, "Job was active longer than specified deadline"
```

at exactly 60m after `startTime`. Building here gives a 6h job budget and drops
the samba build to ~3 min, since it just `FROM`s this image. (Locally it built
in 6.5 min, vs 2532s on the runner — the gap is core count.)

## Usage

```dockerfile
FROM ghcr.io/malarinv/sssd:2.10.1 AS sssdbuilder
# ...
COPY --from=sssdbuilder /stage/usr/ /usr/
```

`/stage/usr`, `/stage/lib` and `/stage/etc` are each real directories. The copy
**must** be piecewise — `COPY --from=... /stage /` fails on debian:trixie with
`cannot copy to non-directory: .../lib`, because `/lib` is a symlink there and
the staged tree contains a real `/lib` directory.

Ordering matters in the consumer: install Debian's `sssd` runtime packages
**first**, then apply this overlay. Reversed, the overlay's stale `/etc/passwd`
and `/etc/group` clobber the `sssd` user Debian just created.

After overlaying, two fixes are required (both handled by the samba image):

```dockerfile
RUN echo "/usr/lib/sssd" > /etc/ld.so.conf.d/sssd.conf && ldconfig
RUN chmod -R a+rx /usr/libexec/sssd
```

- `ldconfig`, or the binary dies at startup with `libsss_util.so: cannot open
  shared object file` — `/usr/lib/sssd` is not on the default loader path.
- `chmod`, because `make install` leaves the responders mode `0750` root-owned
  and the unprivileged `sssd` user cannot exec them (`Could not exec
  /usr/libexec/sssd/sssd_pam ... Permission denied`). Debian ships `0755`.
- Also `find /usr/lib -name '*.la' -delete` — libtool `.la` stubs in the samba
  ldb module dir make ldb fail with `memberof.la : invalid ELF header`.

## Pinning

Consumers pin an immutable version tag (`2.10.1`), never `latest`. A floating
reference would reintroduce the "moved pointer" problem that fetching a pinned
release tarball used to avoid. `<version>-<sha7>` tags let a consumer's
published chart `appVersion` be resolved back to the exact build.

## Build locally

```sh
docker build --target builder --load -t sssd-stage1:test .
```