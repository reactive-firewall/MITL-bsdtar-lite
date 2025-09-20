# syntax=docker/dockerfile:1

# version is passed through by Docker.
# shellcheck disable=SC2154
ARG LIBEXECINFO_VERSION=${LIBEXECINFO_VERSION:-"1.3"}

# version is passed through by Docker.
# shellcheck disable=SC2154
ARG LLVM_VERSION=${LLVM_VERSION:-"21.1.1"}

# version is passed through by Docker.
# shellcheck disable=SC2154
ARG TAR_VERSION=${TAR_VERSION:-"3.8.1"}

# ---- fetcher stage: install and cache required Alpine packages and fetch release tarballs ----

# Use MIT licensed Alpine as the base image for the build environment
# shellcheck disable=SC2154
FROM --platform="linux/${TARGETARCH}" alpine:latest AS fetcher

# Set environment variables
ARG LIBEXECINFO_VERSION=${LIBEXECINFO_VERSION:-"1.3"}
ENV LIBEXECINFO_VERSION=${LIBEXECINFO_VERSION}
ENV LIBEXECINFO_URL="https://github.com/reactive-firewall/libexecinfo/raw/refs/tags/v${LIBEXECINFO_VERSION}/libexecinfo-${LIBEXECINFO_VERSION}r.tar.bz2"
ARG LLVM_VERSION=${LLVM_VERSION:-"21.1.1"}
ENV LLVM_VERSION=${LLVM_VERSION}
ENV LLVM_URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${LLVM_VERSION}.tar.gz"
ARG TAR_VERSION=${TAR_VERSION:-"3.8.1"}
ENV TAR_VERSION=${TAR_VERSION}
ENV LIBARCHIVE_URL="https://github.com/libarchive/libarchive/archive/refs/tags/v${TAR_VERSION}.tar.gz"
ARG ZLIB_VERSION=${ZLIB_VERSION:-"1.3.1"}
ENV ZLIB_VERSION=${ZLIB_VERSION}
ENV ZLIB_URL="https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
WORKDIR /fetch
ENV CC=clang
ENV CXX=clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV LDFLAGS="-fuse-ld=lld"

# Install necessary packages
# ca-certificates - MPL AND MIT - do not bundle - just to verify certificates (weak)
# alpine - MIT - do not bundle - just need an OS (weak)
# curl - curl License / MIT (direct)
# bsdtar - BSD-2 - used to unarchive during bootstrap (transient)
LABEL org.opencontainers.image.vendor="individual"
LABEL org.opencontainers.image.licenses="cURL Apache-2.0 AND MPL"

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk update && \
  apk add \
    ca-certificates \
    curl \
    cmd:bsdtar

# just need a place to fetch
RUN mkdir -p /fetch
WORKDIR /fetch

# Fetch the signed release tarballs (or supply via build-args)
RUN curl -fsSLo libexecinfo-${LIBEXECINFO_VERSION}r.tar.bz2 \
    --url "$LIBEXECINFO_URL" && \
    bsdtar -xzf libexecinfo-${LIBEXECINFO_VERSION}r.tar.bz2 && \
    rm libexecinfo-${LIBEXECINFO_VERSION}r.tar.bz2 && \
    mv /fetch/libexecinfo-${LIBEXECINFO_VERSION}r /fetch/libexecinfo && \
    rm /fetch/libexecinfo/patches.tar.bz2
RUN curl -fsSLo llvmorg-${LLVM_VERSION}.tar.gz \
    --url "$LLVM_URL" && \
    bsdtar -xzf llvmorg-${LLVM_VERSION}.tar.gz && \
    rm llvmorg-${LLVM_VERSION}.tar.gz && \
    mv /fetch/llvm-project-llvmorg-${LLVM_VERSION} /fetch/llvmorg
RUN curl -fsSLo zlib-${ZLIB_VERSION}.tar.gz \
    --url "${ZLIB_URL}" && \
    bsdtar -xzf zlib-${ZLIB_VERSION}.tar.gz && \
    rm zlib-${ZLIB_VERSION}.tar.gz && \
    mv /fetch/zlib-${ZLIB_VERSION} /fetch/zlib
RUN curl -fsSLo v${TAR_VERSION}.tar.gz \
    --url "$LIBARCHIVE_URL" && \
    bsdtar -xzf v${TAR_VERSION}.tar.gz && \
    rm v${TAR_VERSION}.tar.gz && \
    mv /fetch/libarchive-${TAR_VERSION} /fetch/libarchive

# --- builder: bootstrap llvm with distro clang, then build llvm, then build bsdtar statically ---
FROM --platform="linux/${TARGETARCH}" alpine:latest AS pre-bsdtar-builder

# copy ONLY fetched source
COPY --from=fetcher /fetch/libexecinfo /home/builder/libexecinfo
COPY --from=fetcher /fetch/llvmorg /home/builder/llvmorg
COPY --from=fetcher /fetch/zlib /home/builder/zlib
RUN mkdir -p /home/builder/llvmorg/libc/config/baremetal/x86_64
COPY x86_64_musl_entrypoints.txt /home/builder/llvmorg/libc/config/baremetal/x86_64/entrypoints.txt
COPY x86_64_musl_headers.txt /home/builder/llvmorg/libc/config/baremetal/x86_64/headers.txt
COPY --from=fetcher /fetch/libarchive /home/builder/libarchive

ARG TARGET_TRIPLE
ENV TARGET_TRIPLE=${TARGET_TRIPLE}

# provenance ENV (kept intentionally)
ARG LIBEXECINFO_VERSION=${LIBEXECINFO_VERSION:-"1.3"}
ENV LIBEXECINFO_VERSION=${LIBEXECINFO_VERSION}
ENV LIBEXECINFO_URL="https://github.com/reactive-firewall/libexecinfo/raw/refs/tags/v${LIBEXECINFO_VERSION}/libexecinfo-${LIBEXECINFO_VERSION}r.tar.bz2"
ARG LLVM_VERSION=${LLVM_VERSION:-"21.1.1"}
ENV LLVM_VERSION=${LLVM_VERSION}
ENV LLVM_URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${LLVM_VERSION}.tar.gz"
ARG TAR_VERSION=${TAR_VERSION:-"3.8.1"}
ENV TAR_VERSION=${TAR_VERSION}
ENV LIBARCHIVE_URL="https://github.com/libarchive/libarchive/archive/refs/tags/v${TAR_VERSION}.tar.gz"
ARG ZLIB_VERSION=${ZLIB_VERSION:-"1.3.1"}
ENV ZLIB_VERSION=${ZLIB_VERSION}
ENV ZLIB_URL="https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
ENV PATH="/home/builder/llvm/bin:/usr/bin:/usr/local/bin:$PATH"
ENV CC=clang
ENV CXX=clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV LD=lld
ENV STRIP=llvm-strip
ENV BSD=/usr/include/bsd

# Install necessary packages
# llvm - LLVM-apache-2
# clang - llvm-apache-2
# lld - llvm-apache-2
# ninja-build - Apache-2.0
# build-base - MIT
# musl-dev - MIT
# libc6-compat - MIT
# libbsd-dev - BSD-3-Clause
# curl - curl License / MIT
# zlib-dev - zlib license
# zip - Info-ZIP license
# libexecinfo-dev - BSD-2-Clause
LABEL org.opencontainers.image.vendor="individual"
LABEL org.opencontainers.image.licenses="Apache-2.0 AND zlib AND Info-ZIP"

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk update && \
  apk add \
    cmd:bash \
    clang \
    lld \
    llvm \
    cmd:lld \
    cmd:llvm-ar \
    cmd:llvm-otool \
    cmd:llvm-nm \
    cmd:llvm-strip \
    llvm-runtimes \
    cmake \
    make \
    ninja-build \
    cmd:ninja \
    cmd:clang++ \
    musl-dev \
    pkgconfig \
    zlib-dev \
    libbsd-dev \
    zip

# Optional: install minimal compression libs you need, else disable them in CMake
# apk add --no-cache xz-dev bzip2-dev zlib-dev zstd-dev lz4-dev

WORKDIR /home/builder

# make clang -fuse-ld=lld driver test succeed
RUN ln -sf "$(command -v ld.lld)" /usr/local/bin/lld || true

# Build libexecinfo
RUN cd /home/builder/libexecinfo && \
    make && \
    chmod 755 ./install.sh && \
    ./install.sh && \
    cd /home/builder

# Configure LLVM (monorepo layout: projects under llvmorg/)
# Use static for libs based on https://discourse.llvm.org/t/issues-when-building-llvm-clang-from-trunk/70323
RUN mkdir -p /home/builder/llvm && \
    mkdir -p /home/builder/llvmorg/llvm-build && \
    cd /home/builder/llvmorg/ && \
    cmake -S ./llvm -B ./llvm-build -GNinja -Wno-dev \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/home/builder/llvm \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_LINKER=$(command -v ld.lld) \
      -DCMAKE_AR=/usr/bin/llvm-ar \
      -DCMAKE_RANLIB=/usr/bin/llvm-ranlib \
      -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
      -DLIBCXX_HAS_MUSL_LIBC=ON \
      -DLIBCXX_USE_COMPILER_RT=OFF \
      -DLIBCXXABI_USE_COMPILER_RT=OFF \
      -DLLVM_ENABLE_PROJECTS="clang;lld" \
      -DLLVM_TARGETS_TO_BUILD="X86;ARM;AArch64" \
      -DBUILD_SHARED_LIBS=OFF \
      -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_BUILD_TESTS=OFF

# Build LLVM (monorepo layout: projects under llvmorg/)
RUN cd /home/builder/llvmorg/ && \
    cmake --build ./llvm-build --target install -- -j$(nproc)

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk del \
    zlib-dev \
    zip

# DEBUG CODE for SEG FAULT

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk add cmd:file

RUN file /home/builder/llvm/bin/clang-21 \
    /home/builder/llvm/bin/clang \
    /home/builder/llvm/bin/clang++ \
    /home/builder/llvm/bin/llvm-ar \
    /home/builder/llvm/bin/llvm-ranlib \
    /home/builder/llvm/bin/lld \
    /home/builder/llvm/bin/ld

RUN /home/builder/llvm/bin/clang --version && \
    /home/builder/llvm/bin/clang++ --version && \
    /home/builder/llvm/bin/llvm-ar --version

RUN file /home/builder/llvm/bin/lld \
    /home/builder/llvm/bin/llvm-ranlib

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk del cmd:file || true

# END DEBUG CODE

# Ensure new toolchain is first in PATH
ENV PATH=/home/builder/llvm/bin:$PATH
ENV CC=/home/builder/llvm/bin/clang
ENV CXX=/home/builder/llvm/bin/clang++
ENV AR=/home/builder/llvm/bin/llvm-ar
ENV RANLIB=/home/builder/llvm/bin/llvm-ranlib
ENV LD=/home/builder/llvm/bin/lld
ENV STRIP=/home/builder/llvm/bin/llvm-strip

# Configure and build static library only
# zlib's configure uses CC/CFLAGS. We force static archive creation.
WORKDIR /home/builder/zlib
RUN CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" LD="$LD" \
    CFLAGS="-O3 -fPIC -static" \
    ./configure --prefix="/usr/local" \
 && make -j"$(nproc)" libz.a \
 && make install

ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

# Strip the static library to reduce size
RUN strip --strip-unneeded "/usr/local/lib/libz.a" || true

# Build libarchive and bsdtar with static linking
WORKDIR /home/builder/libarchive
RUN mkdir -p build && cd build && \
    cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_LINKER=$(command -v ld.lld) \
      -DCMAKE_AR=llvm-ar \
      -DCMAKE_RANLIB=llvm-ranlib \
      -DBUILD_SHARED_LIBS=OFF \
      -DENABLE_BZIP2=OFF \
      -DENABLE_XZ=OFF \
      -DENABLE_ZSTD=OFF \
      -DENABLE_LZIP=OFF \
      -DENABLE_ZLIB=ON \
      -DENABLE_LZ4=OFF \
      -DENABLE_ICONV=OFF \
      -DENABLE_TESTS=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-fPIC -static -s -fuse-ld=lld" \
      -S .. -B . && \
    cmake --build . --target libarchive.a bsdtar -- -j$(nproc)

# verify staticness (keep artifact small by remove build deps after check)
RUN set -e; \
    if llvm-readelf -a build/bsdtar | grep -q "NEEDED"; then echo "ERROR: bsdtar is dynamically linked"; exit 1; fi; \
    ${STRIP} --strip-all build/bsdtar

# install into ephemeral dir to copy to scratch later
RUN mkdir -p /out/bin && cp build/bsdtar /out/bin/bsdtar

# ---- final stage: artifact only ----
# Final artifact stage: copy bsdtar
FROM scratch AS mitl-bsdtar-lite

LABEL version="20250918"
LABEL org.opencontainers.image.title="MITL-BSDtar-lite"
LABEL org.opencontainers.image.description="Hermetically built BSD tar."
LABEL org.opencontainers.image.vendor="individual"
LABEL org.opencontainers.image.licenses="Apache-2.0 AND BSD-2"

# provenance ENV (kept intentionally)
ENV LLVM_VERSION=${LLVM_VERSION}
ENV LLVM_URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${LLVM_VERSION}.tar.gz"
ENV TAR_VERSION=${TAR_VERSION}
ENV LIBARCHIVE_URL="https://github.com/libarchive/libarchive/archive/refs/tags/v${TAR_VERSION}.tar.gz"
ENV PATH=/usr/bin:/home/builder/llvm/bin
ENV TAR=/usr/bin/bsdtar
ENV CC=clang CXX=clang++ AR=llvm-ar RANLIB=llvm-ranlib LD=lld STRIP=llvm-strip

COPY --from=pre-bsdtar-builder /home/builder/libarchive/build/bsdtar /usr/bin/bsdtar
# If statically linked, bsdtar will be portable; else ensure required runtime libs present
ENTRYPOINT ["/usr/bin/bsdtar"]
