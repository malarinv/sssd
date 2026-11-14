# Rootless-capable SSSD, built from the upstream release tarball.
#
# WHY THIS IMAGE EXISTS
# =====================
# Debian trixie's `sssd` 2.10.1-2+b1 is compiled WITHOUT --with-sssd-user=sssd,
# and such a binary refuses to run unprivileged outright:
#   [sssd] [main] Non-root service user support isn't built. Can't run under 100:101
# That is compile-time (guard in monitor.c behind #ifndef SSSD_NON_ROOT_USER),
# so capabilities, UID mapping and file ownership cannot substitute for it.
#
# It used to be stage 1 of the samba image, which cost ~48 min of build and
# pushed the combined image past the Forgejo runner's 60-minute
# activeDeadlineSeconds (run 7ccs9: "Job was active longer than specified
# deadline", DeadlineExceeded at 60m after startTime). Split out so samba's
# build is ~3 min and the one-time compile runs where the cap is either
# absent or far higher.
#
# CONTRACT with the samba image
# =============================
# Produces the tree the samba Dockerfile copied as
#   COPY --from=sssdbuilder /stage/usr/ /usr/
#   COPY --from=sssdbuilder /stage/lib/ /lib/
#   COPY --from=sssdbuilder /stage/etc/ /etc/
# so /stage/usr, /stage/lib and /stage/etc must each be a real directory -
# `COPY --from=... /stage /` fails on trixie because /lib is a symlink and the
# staged tree contains a real /lib directory.
#
# The ordering in the consumer matters too: the sssd runtime packages are
# installed FIRST and this overlay applies after. Reversed, the overlay's stale
# /etc/passwd and /etc/group (from this build stage) clobber the sssd user.
FROM debian:trixie AS builder
ARG SSSD_VER=2.10.1

# ENV, not per-RUN export: every apt call here is build-only, and this stage
# never ships. Run 4474 died at `ucf failed to preconfigure, with exit status
# 128` after "unable to initialize frontend: Readline / Teletype" complaints -
# debconf walked Dialog -> Readline -> Teletype and failed because a build
# container has no controlling tty. That reads like a broken package list; it
# is a missing environment variable.
ENV DEBIAN_FRONTEND=noninteractive

# Each item below was found by a distinct configure error, and none of dhash,
# the Ding-Libs trio, krad, unistring or the idmap-plugin flags appear in
# upstream's building-sssd.html:
#   libdhash-dev      -> configure: error: "Please install libdhash-devel"
#   libcollection-dev / libpath-utils-dev / libref-array-dev (Ding-Libs)
#   bind9-dnsutils    -> configure: error: nsupdate is not available  (no
#                        --without-nsupdate escape hatch exists; SSSD
#                        hard-requires nsupdate)
#   libkrad-dev       -> configure: error: krad.h not found  (plugin-only dep,
#                        consumed by src/krb5_plugin, NOT by sssd core)
#   libunistring-dev
# libkeyutils-dev and uuid-dev are absent from the documented list too
# (uuid/uuid.h is reached via src/tools/sssctl).
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential curl ca-certificates git python3 uuid-dev \
      libtalloc-dev libtevent-dev libtdb-dev libldb-dev libpopt-dev \
      libpam0g-dev libssl-dev libldap2-dev libsasl2-dev libkrb5-dev libdbus-1-dev \
      libini-config-dev libjansson-dev libc-ares-dev libselinux1-dev \
      libdhash-dev libcollection-dev libpath-utils-dev libref-array-dev \
      libkeyutils-dev libkrad-dev libunistring-dev libcurl4-openssl-dev libjose-dev \
      bind9-dnsutils libxml2-utils libaudit-dev libsemanage-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/SSSD/sssd/releases/download/${SSSD_VER}/sssd-${SSSD_VER}.tar.gz" \
        -o /tmp/s.tar.gz && tar -C /tmp -xzf /tmp/s.tar.gz

# Run ./configure directly. Do NOT run `autoreconf -if`: the release tarball
# already ships a working generated configure/Makefile.in/aclocal.m4, and
# autoreconf breaks it with `possibly undefined macro: LT_LIB_DLLOAD` followed
# by `cannot find required auxiliary files: missing compile`. Upstream's
# autoreconf instruction applies to a git clone, not a release tarball.
#
# Flag spellings matter and wrong ones only WARN (so a build can silently ship
# wrong lib paths that break only at runtime):
#   --enable-nsslibdir=...   (NOT --with-nsslibdir)
#   --enable-pammoddir=...   (NOT --with-pammoddir)
#
# Mandatory on trixie (each one is a configure error, not a warning):
#   --disable-cifs-idmap-plugin          (no cifsidmap.h on Debian)
#   --without-nfsv4-idmapd-plugin        (no libnfsidmap headers) - read the
#                                         error text for this exact name;
#                                         --without-nfs-idmap-plugin is
#                                         silently ignored and configure then
#                                         fails again.
#   --without-samba                      (architectural consequence: this build
#                                         cannot serve id_provider=ad or ipa.
#                                         samba's AD provider needs Samba 4
#                                         libs. LLDAP-based auth uses
#                                         id_provider=ldap and is unaffected.)
#   --with-oidc-child=no
#   --without-kcm
#
# Renderers/responders we do not use are stripped to cut attack surface:
# sudo, ssh, autofs, manpages, the python3 bindings.
RUN cd /tmp/sssd-${SSSD_VER} && ./configure --prefix=/usr --sysconfdir=/etc/sssd \
      --localstatedir=/var/lib/sss --with-sssd-user=sssd --without-kcm \
      --disable-cifs-idmap-plugin --without-samba --without-nfsv4-idmapd-plugin \
      --with-oidc-child=no --without-python3-bindings \
      --enable-nsslibdir=/lib/x86_64-linux-gnu \
      --enable-pammoddir=/lib/x86_64-linux-gnu/security \
      --without-sudo --without-ssh --without-autofs --without-manpages \
      --with-pid-path=/run/sssd/sssd.pid \
    && make -j"$(nproc)" && mkdir -p /stage && make install DESTDIR=/stage \
    && rm -rf /tmp/sssd-${SSSD_VER} /tmp/s.tar.gz

# The consumer needs /stage/usr, /stage/lib and /stage/etc as real directories.
# Only usr/ and lib/ are produced by `make install` on this config; ensure etc/
# exists (it is empty unless a config was installed) so the piecewise COPYs in
# the samba image never fail for a missing path.
RUN mkdir -p /stage/etc

# Not published. The workflow builds `--target builder` and pushes THAT stage,
# because the consumer COPYs `/stage/usr`, `/stage/lib` and `/stage/etc` out of
# it - paths that only exist in the builder. Reproducing the tree at / in a
# scratch image would publish something the samba Dockerfile cannot use
# (verified: its build failed with `"/stage/usr": not found`).
#
# Kept only so `docker build --target builder` has an obvious sibling when
# inspecting the file. A consumer that wants the tree at / can build this
# stage explicitly.
FROM scratch AS scratch-image
COPY --from=builder /stage /