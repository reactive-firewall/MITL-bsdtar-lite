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
COPY generate-toolchain-baremetal.sh /usr/bin/generate-toolchain-baremetal.sh
COPY pick-and-anvil.sh /usr/bin/pick-and-anvil.sh

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
    cmd:dash \
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

# make script excutable
RUN chmod 555 /usr/bin/generate-toolchain-baremetal.sh && \
    chmod 555 /usr/bin/pick-and-anvil.sh

WORKDIR /home/builder

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

# Ensure new toolchain is first in PATH
ENV CC=/home/builder/llvm/bin/clang
ENV CXX=/home/builder/llvm/bin/clang++
ENV AR=/home/builder/llvm/bin/llvm-ar
ENV RANLIB=/home/builder/llvm/bin/llvm-ranlib
ENV LD=lld
ENV LDFLAGS="-fuse-ld=lld"
ENV STRIP=/home/builder/llvm/bin/llvm-strip

# Configure and build static library only
# zlib's configure uses CC/CFLAGS. We force static archive creation.
WORKDIR /home/builder/zlib
RUN CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" LD="$LD" \
    CFLAGS="-O3 -fPIC -static" \
    ./configure --prefix="/usr/local" \
 && make -j"$(nproc)" libz.a \
 && make install

# disabled to rule out issues
# ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

# Strip the static library to reduce size
RUN strip --strip-unneeded "/usr/local/lib/libz.a" || true

## DEBUG CODE

# VALIDATE CLANG
RUN printf "%s\n" 'int main(void) {return 0;}' > sanity.c && \
    /home/builder/llvm/bin/clang -target aarch64-unknown-none-musl -static -nostdlib -fuse-ld=lld sanity.c -o sanity && \
    file sanity

# CHECK toolchain paths
RUN ls -lap /home/builder/llvm/bin/ && \
    ls -lap /home/builder/llvm/include && \
    ls -lap /home/builder/llvm/lib && \
    ls -lap /home/builder/llvm/libexec && \
    ls -lap /home/builder/llvm/

# CHECK lib paths
RUN ls -lap /usr/lib && \
    ls -lap /lib && \
    ls -lap /usr/shar/lib && \
    ls -lap /usr/local/lib && \
    ls -lap /opt/lib && \
    ls -lap /libexec && \
    ls -lap /usr/libecec && \
    ls -lap /libexec && \
    ls -lap /usr/share/libexec && \
    ls -lap /usr/local/libexec && \
    ls -lap /opt/libexec

# Create a directory for the tests
RUN mkdir -p /tests

# Create test source files
RUN echo '#include <stdio.h>\nint main() { printf("Hello, World!\\n"); return 0; }' > /tests/test_syntax.c
RUN echo '#include <stdio.h>\nint main() { int a = 5; float b = 3.2; double c = 4.5; printf("Sum: %f\\n", a + b + c); return 0; }' > /tests/test_data_types.c
RUN echo '#include <stdio.h>\nint main() { for (int i = 0; i < 5; i++) { printf("Iteration: %d\\n", i); } return 0; }' > /tests/test_control_structures.c
RUN echo '#include <stdio.h>\nint add(int x, int y) { return x + y; }\nint main() { printf("Sum: %d\\n", add(3, 4)); return 0; }' > /tests/test_functions.c
RUN echo '#include <assert.h>\nint main() { static_assert(1 == 1, "This should always be true"); return 0; }' > /tests/test_c11_features.c
RUN echo '#include <iostream>\nclass Base { public: virtual void show() { std::cout << "Base class" << std::endl; }}; class Derived : public Base { public: void show() override { std::cout << "Derived class" << std::endl; }}; int main() { Base* b = new Derived(); b->show(); delete b; return 0; }' > /tests/test_classes.cpp
RUN echo '#include <iostream>\n#include <vector>\n#include <algorithm>\nint main() { std::vector<int> vec = {1, 2, 3, 4, 5}; std::for_each(vec.begin(), vec.end(), [](int n) { std::cout << n << " "; }); std::cout << std::endl; return 0; }' > /tests/test_lambda.cpp
RUN echo '#include <iostream>\n#include <stdexcept>\nint main() { try { throw std::runtime_error("An error occurred"); } catch (const std::exception& e) { std::cout << "Caught exception: " << e.what() << std::endl; } return 0; }' > /tests/test_exceptions.cpp
RUN echo '#include <iostream>\ntemplate <typename T> T add(T a, T b) { return a + b; }\nint main() { std::cout << "Sum: " << add(3, 4) << std::endl; return 0; }' > /tests/test_templates.cpp
RUN echo '#include <iostream>\n#include <memory>\nclass MyClass { public: MyClass() { std::cout << "Constructor" << std::endl; } ~MyClass() { std::cout << "Destructor" << std::endl; }};\nint main() { std::unique_ptr<MyClass> ptr(new MyClass()); return 0; }' > /tests/test_smart_pointers.cpp
RUN echo '#include <iostream>\n#include <vector>\nint main() { std::vector<int> vec = {1, 2, 3, 4, 5}; for (int n : vec) { std::cout << n << " "; } std::cout << std::endl; return 0; }' > /tests/test_range_based_for.cpp
RUN echo '#include <iostream>\nconstexpr int square(int x) { return x * x; }\nint main() { std::cout << "Square of 5: " << square(5) << std::endl; return 0; }' > /tests/test_constexpr.cpp
RUN echo '#include <stdio.h>\n#include <pthread.h>\nvoid* print_message(void* ptr) { char* message = (char*)ptr; printf("%s\\n", message); return NULL; }\nint main() { pthread_t thread1; const char* message1 = "Thread 1"; pthread_create(&thread1, NULL, print_message, (void*)message1); pthread_join(thread1, NULL); return 0; }' > /tests/test_threading.c

# Compile and run tests
RUN /path/to/your/toolchain/bin/clang -target ${TARGET_TRIPLE} -o /tests/test_s

## END DEBUG CODE

RUN dash /usr/bin/generate-toolchain-baremetal.sh

# Build libarchive and bsdtar with static linking
WORKDIR /home/builder/libarchive
RUN mkdir -p build && cd build && \
    cmake -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=../toolchain-baremetal.cmake \
      -DBUILD_SHARED_LIBS=OFF \
      -DENABLE_ACL=OFF \
      -DENABLE_XATTR=OFF \
      -DENABLE_LZMA=OFF \
      -DENABLE_BZIP2=OFF \
      -DENABLE_XZ=OFF \
      -DENABLE_ZSTD=OFF \
      -DENABLE_LZIP=OFF \
      -DENABLE_ZLIB=ON \
      -DENABLE_LZ4=OFF \
      -DENABLE_ICONV=OFF \
      -DENABLE_TESTS=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-fPIC -static -s" \
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
