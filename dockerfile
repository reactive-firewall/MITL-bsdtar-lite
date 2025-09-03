# syntax=docker/dockerfile:1

# version is passed through by Docker.
# shellcheck disable=SC2154
ARG LLVM_VERSION=${LLVM_VERSION:-"21.1.0"}

# version is passed through by Docker.
# shellcheck disable=SC2154
ARG TAR_VERSION=${TAR_VERSION:-"3.8.1"}

# ---- fetcher stage: install and cache required Alpine packages and fetch release tarballs ----

# Use MIT licensed Alpine as the base image for the build environment
# shellcheck disable=SC2154
FROM --platform="linux/${TARGETARCH}" alpine:latest AS fetcher

# Set environment variables
ENV LLVM_VERSION=${LLVM_VERSION:-"21.1.0"}
ENV LLVM_URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${LLVM_VERSION}.tar.gz"
ENV TAR_VERSION=${TAR_VERSION:-"3.8.1"}
ENV LIBARCHIVE_URL="https://github.com/libarchive/libarchive/archive/refs/tags/v${TAR_VERSION}.tar.gz"
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
# bsdtar - BSD-2 - used to unarchive during bootstrap (transiant)
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
RUN curl -fsSLo llvmorg-${LLVM_VERSION}.tar.gz \
    --url "$LLVM_URL" && \
    bsdtar -xzf llvmorg-${LLVM_VERSION}.tar.gz && \
    rm llvmorg-${LLVM_VERSION}.tar.gz && \
    mv /fetch/llvm-project-llvmorg-${LLVM_VERSION} /fetch/llvmorg
RUN curl -fsSLo v${TAR_VERSION}.tar.gz \
    --url "$LIBARCHIVE_URL" && \
    bsdtar -xzf v${TAR_VERSION}.tar.gz && \
    rm v${TAR_VERSION}.tar.gz && \
    mv /fetch/libarchive-${TAR_VERSION} /fetch/libarchive

# --- builder: bootstrap llvm with distro clang, then build llvm, then build bsdtar statically ---
FROM --platform="linux/${TARGETARCH}" alpine:latest AS pre-bsdtar-builder

# copy ONLY fetched source
COPY --from=fetcher /fetch/llvmorg /home/builder/llvmorg
COPY --from=fetcher /fetch/libarchive /home/builder/libarchive

# provenance ENV (kept intentionally)
ENV LLVM_VERSION=${LLVM_VERSION}
ENV LLVM_URL="https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-${LLVM_VERSION}.tar.gz"
ENV TAR_VERSION=${TAR_VERSION}
ENV LIBARCHIVE_URL="https://github.com/libarchive/libarchive/archive/refs/tags/v${TAR_VERSION}.tar.gz"
ENV PATH="/usr/local/bin:/home/builder/llvm/bin:$PATH"
ENV CC=clang
ENV CXX=clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV LD=lld
ENV LDFLAGS="-fuse-ld=lld"
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
LABEL org.opencontainers.image.vendor="individual"
LABEL org.opencontainers.image.licenses="Apache-2.0 AND zlib AND Info-ZIP"

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked --network=default \
  apk update && \
  apk add \
    cmd:bash \
    clang \
    lld \
    llvm \
    cmake \
    make \
    ninja-build \
    cmd:ninja \
    cmd:clang++ \
    musl-dev \
    libc6-compat \
    pkgconfig \
    zlib-dev \
    libbsd-dev \
    zip \
    build-base

# Optional: install minimal compression libs you need, else disable them in CMake
# apk add --no-cache xz-dev bzip2-dev zlib-dev zstd-dev lz4-dev

WORKDIR /home/builder

# Build LLVM (monorepo layout: projects under llvmorg/)
RUN mkdir -p /home/builder/llvm && \
    mkdir -p /home/builder/llvmorg/llvm-build && \
    cd /home/builder/llvmorg/llvm-build && \
    cmake -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/home/builder/llvm \
      -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt" \
      -DLLVM_ENABLE_RUNTIMES="" \
      -DLLVM_USE_LINKER=lld -DCMAKE_C_COMPILER=clang \
      ../llvm && \
    cmake --build . --target install --parallel $(nproc)

# Ensure new toolchain is first in PATH
ENV PATH=/home/builder/llvm/bin:$PATH
ENV CC=/home/builder/llvm/bin/clang
ENV CXX=/home/builder/llvm/bin/clang++
ENV AR=/home/builder/llvm/bin/llvm-ar
ENV RANLIB=/home/builder/llvm/bin/llvm-ranlib
ENV LD=/home/builder/llvm/bin/lld
ENV STRIP=/home/builder/llvm/bin/llvm-strip

# Build libarchive and bsdtar with static linking
WORKDIR /home/builder/libarchive
RUN mkdir -p build && cd build && \
    cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=${CC} \
      -DCMAKE_CXX_COMPILER=${CXX} \
      -DCMAKE_AR=${AR} \
      -DCMAKE_RANLIB=${RANLIB} \
      -DBUILD_SHARED_LIBS=OFF \
      -DENABLE_BZIP2=OFF \
      -DENABLE_XZ=OFF \
      -DENABLE_ZSTD=OFF \
      -DENABLE_LZIP=OFF \
      -DENABLE_ZLIB=ON \
      -DENABLE_LZ4=OFF \
      -DENABLE_ICONV=OFF \
      -DENABLE_TESTS=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-static -s -fuse-ld=lld" \
      -S .. -B . && \
    cmake --build . --target libarchive bsdtar -- -j$(nproc)

# verify staticness (keep artifact small by remove build deps after check)
RUN set -e; \
    if readelf -a build/bsdtar | grep -q "NEEDED"; then echo "ERROR: bsdtar is dynamically linked"; exit 1; fi; \
    ${STRIP} --strip-all build/bsdtar

# install into ephemeral dir to copy to scratch later
RUN mkdir -p /out/bin && cp build/bsdtar /out/bin/bsdtar

# ---- final stage: artifact only ----
# Final artifact stage: copy bsdtar
FROM scratch AS mitl-bsdtar-lite

LABEL version="20250902"
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
