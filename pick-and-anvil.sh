#!/bin/dash
# pick-and-anvil.sh
# POSIX/dash script to discover toolchain components and report types and metadata.
# Designed to run in minimal CI images (alpine, ubuntu, macOS runners).
# Date: 2025-09-20

# Exit on error (but keep pipes safe)
set -eu

### Configuration
# Paths to probe: PATH plus common toolchain directories
PATHS_TO_PROBE="$(printf "%s:" "$PATH")/usr/bin:/usr/local/bin:/opt/local/bin:/opt/bin:/usr/local/clang/bin:/usr/local/gcc/bin:/usr/bin:/bin:/sbin:/usr/local/sbin:/usr/libexec"

# Minimal tools we might use; record presence
have()
{
  command -v "$1" >/dev/null 2>&1
}

# Safely run a command that may not exist; prints nothing on failure
safe_cmd()
{
  if have "$1"; then
    shift
    "$1" "$@" 2>/dev/null || true
  fi
}

# Helpers: join lines into JSON array (simple)
json_escape()
{
  # escape quotes and backslashes
  awk '{
    gsub(/\\/,"\\\\");
    gsub(/"/,"\\\"");
    print
  }'
}

# Print header for logs
timestamp()
{
  if have date; then date -u +"%Y-%m-%dT%H:%M:%SZ"; fi
}

# Detect host OS
detect_os()
{
  uname_s="$(uname -s 2>/dev/null || true)"
  case "$uname_s" in
    Linux) printf '%s\n' linux ;;
    Darwin) printf '%s\n' darwin ;;
    FreeBSD) printf '%s\n' freebsd ;;
    *) printf '%s\n' unknown ;;
  esac
}

OS="$(detect_os)"

# Which file-like inspectors are available
HAS_FILE=0
HAS_STAT=0
HAS_READLINK=0
HAS_NM=0
HAS_OBJDUMP=0
HAS_LLVM_OBJDUMP=0
HAS_OTOOl=0
HAS_STRINGS=0
HAS_HEXDUMP=0

if have file; then HAS_FILE=1; fi
if have stat; then HAS_STAT=1; fi
if have readlink; then HAS_READLINK=1; fi
if have nm; then HAS_NM=1; fi
if have objdump; then HAS_OBJDUMP=1; fi
if have llvm-objdump; then HAS_LLVM_OBJDUMP=1; fi
# otool on darwin may be capitalized differently in some environments
if have otool; then HAS_OTOOl=1; fi
if have strings; then HAS_STRINGS=1; fi
if have hexdump; then HAS_HEXDUMP=1; fi

# Candidate names and heuristics for component types
# Ordered lists: longer names first to prefer multi-part toolchain prefixes
CANDIDATE_PREFIXES='aarch64-none-linux-gnu- arm-none-eabi- arm-linux-gnueabi- x86_64-w64-mingw32- x86_64-linux-gnu- x86_64-apple-darwin- i686-w64-mingw32- riscv64-unknown-elf- riscv64-linux-gnu- powerpc64le- linux-gnu-'
# Common tool names and role hints
# format: name_pattern:role
COMMON_TOOLS='addr2line:debugger-helper
addr2line-gnu:debugger-helper
addr2line-:debugger-helper
anvil-lens:focused
api:misc
ar:archiver
ar-:archiver
aria2c:network-tool
asm:assembler
as:assembler
awk:inspector
autoconf:build-tool
autoconf-:build-tool
automake:build-tool
automake-:build-tool
autoupdate:build-tool
autoupdate-:build-tool
awk:inspector
awk-tool:inspector
babel:build-tool
bandit:security-scanner
bash:language-runtime
beautysh:formatter
bison:bison
bison-:bison
build-id:inspector
buildah:container-builder
bundle:package-manager
bundler:package-manager
cc:c-compiler
cc-wrapper:c-compiler-wrapper
cc-wrapper-:compiler-wrapper
ccache:wrapper
c++:c++-compiler
c++-wrapper:c++-compiler-wrapper
c++-wrapper-:compiler-wrapper
c++filt:demangler
c++filt-:demangler
cargo:build-tool
certtool:cert-tool
cfssl:cert-tool
cfssljson:cert-helper
checkmake:linter
chrpath:binary-patcher
chrpath-:binary-patcher
chisel:network-tool
clang:c-compiler
clang-:c-compiler
clang-format:formatter
clang-format-:formatter
clang-tidy:linter
clang-tidy-:linter
clang++:c++-compiler
clang++-:c++-compiler
clang-wrapper:compiler-wrapper
clear:sysadmin
clippy:linter
cmake:build-tool
cmake-:build-tool
cmake3:build-tool
collect2:linker-helper
collect-ld:linker-helper
configure:build-tool
containerd:container-runtime
contour:network-tool
coreutils:inspector
cobertura:coverage-tool
cpp:preprocessor
cppcheck:linter
cppcheck-:linter
cp:sysadmin
crictl:container-runtime
cscope:inspector
ctest:tester
ctest-:tester
curl:network-tool
csc:csharp-compiler
dart:language-runtime
dd:inspector
debhelper:package-tools
debugfs:fs-debug-tool
demumble:demangler
dep:dependency-tool
des:inspector
df:inspector
diff:inspector
dir:inspector
distcc:distributed-compiler
distcc-pump:distributed-compiler
docker:container-tool
docker-compose:container-tool
dot:graph-tool
dpkg:dpkg-tool
dpkg-deb:package-tools
dpkg-query:package-query
dtrace:dtrace
du:inspector
e2fsck:fs-tool
ebr:inspector
editor:inspector
elfdump:inspector
elfutils:inspector
elfutils-nm:object-inspector
elfutils-objdump:object-inspector
elfutils-readelf:object-inspector
env:inspector
env-tool:inspector
envvar:inspector
ethtool:network-tool
eu-nm:object-inspector
eu-objdump:object-inspector
eu-readelf:object-inspector
eu-stack:inspector
eu-unstrip:stripper
fakeroot:privilege-helper
fakeroot-debian:privilege-helper
fakeroot-tcp:privilege-helper
fasm:assembler
ffmpeg:multimedia
figlet:inspector
file:inspector
file-:inspector
filewrapper:inspector
find:inspector
fisher:inspector
flex:flex
flamegraph:profiler-helper
fold:inspector
fmt:formatter
fmt-:formatter
fpm:package-tools
fuse:fs-tool
g++:c++-compiler
g++-:c++-compiler
g++-multilib:c++-compiler
g++-wrapper:compiler-wrapper
g++-wrapper-:compiler-wrapper
gdb:debugger
gdb-:debugger
gdb-multiarch:debugger
gdbserver:debugger-helper
gdbserver-:debugger-helper
gofmt:formatter
gofmt-:formatter
go:language-compiler
gofmt:formatter
goimports:formatter
go tool pprof:profiler
gprof:profiler
gprof2dot:profiler-helper
gradle:build-tool
gradlew:build-tool
gpg:gpg-tool
gpg2:gpg-tool
gpg-agent:gpg-helper
gpgv:gpg-validator
gh:gh-cli
gh-actions:gh-helper
gh-release:gh-helper
git:vc-tool
git-lfs:vc-helper
git-crypt:vc-helper
git-secret:vc-helper
gitsome:vc-helper
gitlab-runner:ci-tool
glibc:runtime
gmake:build-tool
gofmt:formatter
go vet:inspector
gofmt-:formatter
gofmt-tool:formatter
g++-multilib:c++-compiler
gcc:c-compiler
gcc-:c-compiler
gcc-multilib:c-compiler
gcc-ar:archiver
gcc-nm:object-inspector
gcc-ranlib:archiver-helper
gcc-strip:stripper
gccgo:language-compiler
gettext:inspector
gh:gh-cli
gh-pages:gh-helper
gh-release:gh-helper
gh:gh-cli
g++:c++-compiler
gitlab-ci-multi-runner:ci-tool
gofmt:formatter
gofmt-:formatter
gofmt-tool:formatter
goleak:inspector
go test:tester
gradle-wrapper:build-tool
groff:inspector
gprof2dot:profiler-helper
gpgv:validator
grep:inspector
grcov:coverage-tool
groovy:language-runtime
gunzip:inspector
gzip:inspector
hadolint:linter
hhvm:language-runtime
hg:vc-tool
hexedit:inspector
heimdall:inspector
hfsutils:fs-tool
htop:inspector
html-xml-utils:inspector
hugo:static-site
icu-config:inspector
ideviceinstaller:inspector
identify:inspector
iftop:network-tool
ifconfig:network-tool
imagemagick:inspector
inkscape:inspector
install:installer-helper
install-sh:installer-helper
intltool:inspector
ip:network-tool
iproute2:network-tool
iptables:firewall-tool
ipvsadm:network-tool
jar:archiver
jlink:jlink-tool
javac:language-compiler
java:language-runtime
jarsigner:signer
jetbrains-toolbox:inspector
jq:inspector
jruby:language-runtime
jslint:linter
jsdoc:inspector
jsonlint:inspector
k3s:k8s-tool
k9s:k8s-tool
k6:load-test
kpartx:block-device
kubeadm:kube-tool
kubectl:k8s-tool
kustomize:kustomize-tool
kotlin:language-compiler
kotlinc:language-compiler
kswapd:inspector
ld:linker
ld-.so:runtime-inspector
ld.bfd:linker
ld.lld:linker
ld64:linker
ldconfig:runtime-inspector
ldd:runtime-inspector
ldd-:runtime-inspector
ld-elf.so.1:runtime-inspector
ld-linux.so.2:runtime-inspector
ld-linux-x86-64.so.2:runtime-inspector
ld.so:runtime-inspector
ld.so.1:runtime-inspector
ld-2..so:runtime-inspector
les:inspector
less:inspector
libtool:build-tool
libtool-:build-tool
libtoolize:build-tool
ldd-static:runtime-inspector
lcov:coverage-tool
lcov-geninfo:coverage-tool
lfr:inspector
lf:inspector
ldconfig-wrapper:runtime-inspector
ld-wrapper:linker
ld-wrapper-:linker
ld-wrapper-tool:linker
ldd-wrapper:runtime-inspector
ld-wrapper-gnu:linker
ld-wrapper-:linker
lesspipe:inspector
lex:flex
lex-:flex
llvm-ar:archiver
llvm-cov:coverage-tool
llvm-cov-:coverage-tool
llvm-objdump:object-inspector
llvm-objcopy:object-copier
llvm-nm:object-inspector
llvm-readobj:object-inspector
llvm-link:linker
llvm-lld:linker
llvm-profdata:profiler-helper
llvm-profdata-merge:profiler-helper
llvm-strip:stripper
ltrace:tracer
ltrace-:tracer
lsof:inspector
lsblk:blkid-tool
lsmod:inspector
ls:inspector
lscpu:inspector
m4:m4-preprocessor
m4-:m4-preprocessor
make:build-tool
make-:build-tool
man:inspector
meson:build-tool
meson-:build-tool
minikube:minikube-tool
mint:inspector
mkfs:fs-tool
mkfs.xfs:fs-tool
mktemp:inspector
mksquashfs:squashfs-tool
mlocate:inspector
modinfo:module-tool
modprobe:module-tool
mount:sysadmin
mount.cifs:cifs-tool
mount.nfs:nfs-tool
mount-smb:mount-tool
mongo:database-tool
mosh:remote-tool
maven:maven
mvn:maven
mvnw:maven
mysql:mysql-tool
mysqld:mysql-tool
nc:ncat
ncat:network-tool
netcat:network-tool
netstat:netstat-tool
ninja:ninja-build-tool
ninja-:ninja-build-tool
node:language-runtime
npm:package-manager
npx:package-runner
nsenter:namespace-tool
nss:inspector
nsswitch:inspector
numactl:inspector
objcopy:object-copier
objcopy-:object-copier
objdump:object-inspector
objdump-:object-inspector
od:inspector
openssl:crypto-tool
openssl-req:crypto-helper
openssl-rsa:key-tool
openssl-x509:cert-tool
otool:object-inspector
otool-:object-inspector
packer:build-tool
pacman:package-manager
parted:parted-tool
patchelf:binary-patcher
patchelf-:binary-patcher
perl:language-runtime
perl5:language-runtime
php:language-runtime
phpunit:tester
pip:installer-helper
pip3:installer-helper
pkg:package-manager
pkg_add:package-manager
pkg-config:pkg-config
pkgconf:pkg-config
pkg_info:package-manager
pkg_delete:package-manager
pkg_add:package-manager
pkg_install:package-manager
pkg-config-wrapper:pkg-config
pkgconf-:pkg-config
pipenv:env-tool
pipenv-:env-tool
pip-tools:installer-helper
pprof:profiler
pprof-:profiler
powershell:powershell-runtime
powertop:inspector
prlimit:inspector
prips:inspector
profiler-tool:profiler
ps:inspector
pulseaudio:inspector
python:language-runtime
python2:language-runtime
python3:language-runtime
pyinstaller:packager
pyenv:toolchain-manager
pyenv-:toolchain-manager
pahole:inspector
pahole-:inspector
pkg-config-:pkg-config
pkgconf-:pkg-config
pkg-config-:pkg-config
pkg-config-wrapper:pkg-config
ppc64le-:arch
powershell-core:language-runtime
prettier:formatter
psql:db-tool
pstree:inspector
puppet:config-tool
pulumi:infra-tool
p4:vc-tool
qemu-img:qemu-tool
qemu-nbd:qemu-tool
qemu-system-aarch64:qemu
qemu-system-arm:qemu
qemu-system-x86_64:qemu
qemu-user:qemu-user
qemu-user-static:qemu-user
rake:build-tool
rbenv:toolchain-manager
rb:language-runtime
readelf:object-inspector
readelf-:object-inspector
readelf-static:object-inspector
rpm:rpm-tool
rsync:sync-tool
rustc:language-compiler
rustc-:language-compiler
rustup:toolchain-manager
rr:record-replay-debugger
rr-:record-replay-debugger
rr-replay-:replay-helper
rpm2cpio:package-tools
rs:inspector
rsync-:sync-tool
rtld:runtime-inspector
ruby:language-runtime
runit:service-tool
sccache:wrapper
sccache-wrapper:wrapper
sed:inspector
semgrep:linter
setpriv:privilege-helper
sgdisk:gdisk-tool
sh:language-runtime
shfmt:formatter
sha256sum:inspector
shellcheck:linter
shunit2:tester
skopeo:container-registry
socat:network-tool
socat-:network-tool
softwareupdate:inspector
ss:netstat-tool
scp:sync-tool
sftp:sftp
ssh:remote-tool
ssh-copy-id:helper
ssh-keygen:key-tool
sigstore:signing-tool
signing-tool:signing-tool
sigstore-:signing-tool
smee:inspector
snort:inspector
snyk:security-scanner
snmp:inspector
sort:inspector
spawn:inspector
sqlite3:db-tool
sshd:ssh-server
sshfs:fs-tool
strace:tracer
strace-:tracer
strings:inspector
strip:stripper
strip-:stripper
strip-debug:stripper
strip-debug-symbols:stripper
stty:inspector
sudo:privilege-helper
su:privilege-helper
su-exec:privilege-helper
sum:inspector
swig:inspector
swiftc:language-compiler
swift-format:formatter
systemctl:service-tool
systemtap:tracer
tar:archiver
tasksel:inspector
tcpdump:network-tool
terraform:infra-tool
test:tester
texinfo:inspector
time:inspector
tput:inspector
tune2fs:fs-tool
tzdata:inspector
uaac:inspector
umount:sysadmin
unshare:namespace-tool
unzip:inspector
update-alternatives:inspector
uptime:inspector
url:inspector
uuidgen:inspector
vc-tool:inspector
vim:editor
virtualenv:env-tool
virtualenv-*:env-tool
virt-install:vm-tool
vagrant:vagrant-tool
vcs:inspector
vulkaninfo:inspector
wasm-ld:linker
watchman:inspector
wc:inspector
wget:network-tool
whoami:inspector
wine:compat-tool
winetricks:compat-tool
wrkdir:inspector
xargs:inspector
xz:archiver
xzcat:inspector
xml:inspector
xmlstarlet:inspector
xzgrep:inspector
yal:inspector
yarn:package-manager
yq:inspector
zip:archiver
zypper:package-manager
zstd:zstd-tool'
# Convert COMMON_TOOLS into easy-to-iterate lines (POSIX)
printf '%s\n' "$COMMON_TOOLS" >/tmp/tci_common_tools.$ 2>/dev/null || true
COMMON_FILE=/tmp/tci_common_tools.$

# Output formatting functions
print_header()
{
  printf '%s\n' "## Toolchain Inspector Report"
  printf '%s\n' "timestamp=$(timestamp)"
  printf '%s\n' "host_os=$OS"
  printf '%s\n\n' "probe_paths=$PATHS_TO_PROBE"
}

# Emit a machine-parseable KV block and a compact JSON-like block for each match
report_match()
{
  # args: path role detail type arch flavor
  path="$1"; role="$2"; detail="$3"
  type="$4"; arch="$5"; flavor="$6"
  printf "found.path=%s\n" "$path"
  printf "found.role=%s\n" "$role"
  printf "found.detail=%s\n" "$detail"
  printf "found.type=%s\n" "$type"
  [ -n "$arch" ] && printf "found.arch=%s\n" "$arch"
  [ -n "$flavor" ] && printf "found.flavor=%s\n" "$flavor"
  printf '%s\n' "---"
}

# Determine binary type/arch using available tools
inspect_binary_basic()
{
  # param: path
  p="$1"
  magic=''
  arch=''
  fmt=''
  # file gives richest info
  if [ "$HAS_FILE" -eq 1 ]; then
    magic="$(file -Lb "$p" 2>/dev/null || true)"
  fi
  # On ELF: use readelf or objdump to get architecture
  if [ -n "$magic" ]; then
    case "$magic" in
      *ELF*) fmt=elf ;;
      *Mach-O*) fmt=macho ;;
      *PE32*|*PE32+*) fmt=pe ;;
      *script*sh*) fmt=script ;;
      *executable*|'*executable'*) fmt=exe ;;
      *) fmt=unknown ;;
    esac
  fi
  # Try to extract arch strings heuristically
  if [ "$fmt" = "elf" ]; then
    if have readelf; then
      arch="$(readelf -h "$p" 2>/dev/null | awk -F: '/Machine:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    elif [ "$HAS_OBJDUMP" -eq 1 ]; then
      arch="$(objdump -f "$p" 2>/dev/null | awk -F, '/file format/ {print $1}' | head -n1)"
    fi
  elif [ "$fmt" = "macho" ]; then
    if have otool; then
      arch="$(otool -hv "$p" 2>/dev/null | awk 'NR==1{print $2,$3,$4; exit}')"
    fi
  else
    # fallback: strings grep
    if [ "$HAS_STRINGS" -eq 1 ]; then
      arch="$(strings "$p" 2>/dev/null | grep -m1 -E 'x86_64|i386|ARM|aarch64|riscv' || true)"
    fi
  fi
  printf '%s\n' "$fmt|$arch|$magic"
}

# Classify a filename (basename) by pattern matching
classify_by_name()
{
  bn="$1"
  # strip possible prefix and version suffixes
  # known roles
  # Multi-word: check explicit tokens
  case "$bn" in
    *-gcc|gcc*|*/gcc) printf '%s\n' c-compiler; return ;;
    *-g++|g++*|*/g\+\+) printf '%s\n' c++-compiler; return ;;
    *-clang|clang*|*/clang) printf '%s\n' c-compiler; return ;;
    *-clang++|clang++*) printf '%s\n' c++-compiler; return ;;
    *-gfortran|gfortran*) printf '%s\n' fortran-compiler; return ;;
    *-ld|ld*|*/ld) printf '%s\n' linker; return ;;
    *-lld|lld*|*/lld) printf '%s\n' linker; return ;;
    *-gold|gold*|*/gold) printf '%s\n' linker; return ;;
    *-ar|ar*|*/ar) printf '%s\n' archiver; return ;;
    *-ranlib|ranlib*|*/ranlib) printf '%s\n' archiver-helper; return ;;
    *-objcopy|objcopy*|*/objcopy) printf '%s\n' object-copier; return ;;
    *-objdump|objdump*|*/objdump) printf '%s\n' object-inspector; return ;;
    *-nm|nm*|*/nm) printf '%s\n' object-inspector; return ;;
    *-strip|strip*|*/strip) printf '%s\n' stripper; return ;;
    *-c++filt|c++filt*|*/c++filt) printf '%s\n' demangler; return ;;
    *-addr2line|addr2line*|*/addr2line) printf '%s\n' debugger-helper; return ;;
    *-gdb|gdb*|*/gdb) printf '%s\n' debugger; return ;;
    *-lldb|lldb*|*/lldb) printf '%s\n' debugger; return ;;
    *-ccache|ccache*|*/ccache) printf '%s\n' wrapper; return ;;
    *-sccache|sccache*|*/sccache) printf '%s\n' wrapper; return ;;
    *-pkg-config|pkg-config*|*/pkg-config) printf '%s\n' pkg-config; return ;;
    *-patchelf|patchelf*|*/patchelf) printf '%s\n' binary-patcher; return ;;
    *-otool|otool*|*/otool) printf '%s\n' object-inspector; return ;;
    *-clang-format|clang-format*|*/clang-format) printf '%s\n' formatter; return ;;
    *-clang-tidy|clang-tidy*|*/clang-tidy) printf '%s\n' linter; return ;;
    *) printf '%s\n' unknown; return ;;
  esac
}

# Expand candidate paths by scanning PATH and known locations
gather_candidates()
{
  # produce newline-separated list to stdout
  for pdir in $(printf "%s" "$PATHS_TO_PROBE" | tr ':' ' '); do
    [ -d "$pdir" ] || continue
    # list files (not recursive) to keep cheap
    # Use /bin/ls if available, otherwise shell globbing
    if have ls; then
      for f in "$pdir"/* ; do
        [ -e "$f" ] || continue
        [ -x "$f" ] || continue
        printf "%s\n" "$f"
      done
    else
      for f in "$pdir"/*; do
        [ -e "$f" ] || continue
        [ -x "$f" ] || continue
        printf "%s\n" "$f"
      done
    fi
  done
}

# Main probe routine
main_probe()
{
  print_header

  # Keep a simple JSON-ish array start
  printf '%s\n' "results.start=["
  first=1

  # iterate over candidates
  gather_candidates | while IFS= read -r fp; do
    bn="$(basename "$fp")"

    # skip obviously irrelevant executables quickly
    case "$bn" in
      *.py|*.pl|*.sh|*.rb) : ;; # keep, might be wrappers; don't skip aggressively
    esac

    # Determine probable role by name
    role="$(classify_by_name "$bn")"

    # detect known toolchain prefix (e.g., x86_64-linux-gnu-gcc)
    prefix=''
    for pref in $CANDIDATE_PREFIXES; do
      case "$bn" in
        ${pref}*) prefix="$pref"; break ;;
      esac
    done

    # If no role from exact name, check common tool map
    if [ "$role" = "unknown" ]; then
      # consult COMMON_FILE
      while IFS= read -r line; do
        name=$(printf "%s" "$line" | awk -F: '{print $1}')
        r=$(printf "%s" "$line" | awk -F: '{print $2}')
        case "$bn" in
          "$name" | *"$name"*) role="$r"; break ;;
        esac
      done <"$COMMON_FILE"
    fi

    # Basic file inspection to refine
    inspect="$(inspect_binary_basic "$fp")"
    fmt="$(printf "%s" "$inspect" | awk -F'|' '{print $1}')"
    arch="$(printf "%s" "$inspect" | awk -F'|' '{print $2}')"
    magic="$(printf "%s" "$inspect" | awk -F'|' '{print $3}')"

    # If still unknown, try content-based detection for compilers & linkers
    if [ "$role" = "unknown" ]; then
      # check help output if executable and small
      case "$(dd if="$fp" bs=1 count=1024 2>/dev/null | strings || true)" in
        *"GNU assembler"*) role=assembler ;;
        *"GNU ld"*) role=linker ;;
        *"GNU Gas"*) role=assembler ;;
        *"clang version"*) role=c-compiler ;;
        *"gcc version"*) role=c-compiler ;;
        *"gfortran"*) role=fortran-compiler ;;
        *"GNU objcopy"*) role=object-copier ;;
        *"GNU objdump"*) role=object-inspector ;;
        *) : ;;
      esac
    fi

    # Add arch info for cross-prefixed tools
    flavor=''
    if [ -n "$prefix" ]; then
      flavor="$prefix"
      # derive probable target triplet
      roleprefix="$(printf "%s" "$bn" | sed "s/^${prefix}//")"
      # If remainder starts with gcc/g++, classify more specifically
      case "$roleprefix" in
        gcc*|g\+\+*|clang*|cc) : ;;
        *) : ;;
      esac
    fi

    # Report only if role is not unknown or if look promising (file says ELF/Mach-O/PE)
    report=0
    if [ "$role" != "unknown" ]; then report=1; fi
    if [ "$fmt" = "elf" ] || [ "$fmt" = "macho" ] || [ "$fmt" = "pe" ]; then report=1; fi

    if [ "$report" -eq 1 ]; then
      # Print a JSON-ish entry for machine parsing (minimal)
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf '%s\n' ","
      fi
      # Build compact object: path, role, fmt, arch, flavor, magic (escaped)
      printf "{ \"path\":\"%s\", \"name\":\"%s\", \"role\":\"%s\", \"fmt\":\"%s\", \"arch\":\"%s\", \"flavor\":\"%s\", \"magic\":\"" "$fp" "$bn" "$role" "$fmt" "$arch" "$flavor"
      # escape magic safely
      printf "%s" "$magic" | json_escape | awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print}'  | tr -d '\n' | sed 's/"/\\"/g'
      printf "\" }"
      # Also print a human-friendly KV block
      printf '%s\n' ""
      report_match "$fp" "$role" "$bn" "$fmt" "$arch" "$flavor"
    fi

  done

  printf '\n%s\n\n' "]"
  printf '%s\n' "summary.note=Report contains JSON-like array in results.start and repeated KV sections separated by ---"
  printf '%s\n' "END"
}

# Run main
main_probe
# cleanup
rm -f "$COMMON_FILE" 2>/dev/null || true
exit 0
