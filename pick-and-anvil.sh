#!/bin/dash
# POSIX / dash-compatible toolchain inspector
# Minimal dependencies; checks availability of optional inspection tools.
# Designed for CI/container environments (alpine, ubuntu, macOS, FreeBSD).
# Author: Generated for user request; follow SOLID and small-function design.

# --- Configuration ---
# Extra directories to search besides $PATH
EXTRA_DIRS="/usr/bin /usr/local/bin /opt/bin /opt/local/bin /usr/libexec /usr/local/libexec /usr/sbin /usr/local/sbin /tools/bin /usr/local/clang/bin /usr/local/gcc/bin"

# File name patterns that commonly indicate toolchain components
COMMON_NAMES="gcc g\+\+ cc c++ clang clang++ clang-cl ld lld gold as as86 asarm ar ranlib nm objcopy objdump readelf readelf64 readelf32 strings strip file c++filt addr2line ar.pl cc1 cc1plus ld.bfd ld.gold ld.lld lto1 collect2 gcc-ar gcc-nm gfortran f95 g77 gfortran-10 ccache sccache rustc cargo lld-link llvm-nm llvm-objdump llvm-readobj llvm-readelf llvm-strip llvm-ar ld64 ld64.lld dsymutil otool otool64 lipo dsymutil"

# Where to log (stdout by default)
OUT="/dev/stdout"

# --- Helpers: check availability of optional tools ---
have() {
  command -v "$1" >/dev/null 2>&1
}

# Run a command safely capturing output (first arg is command)
run_safe() {
  # usage: run_safe cmd args...
  # returns code of command; prints stdout to stdout if any
  "$@" 2>/dev/null
  return $?
}

# Print header for a candidate
print_header() {
  printf '%s\n' "------------------------------------------------------------" >>"$OUT"
  printf 'PATH: %s\n' "$1" >>"$OUT"
}

# Emit a key:value pair
emit() {
  # emit "Key: Value"
  printf '%s: %s\n' "$1" "$2" >>"$OUT"
}

# Try to determine file type using 'file' if present, otherwise use simple heuristics
detect_file_type() {
  f="$1"
  if have file; then
    file -L "$f" 2>/dev/null
    return
  fi
  # Fallback: read magic bytes (ELF/Mach-O/#!)
  if [ -r "$f" ]; then
    head -c 4 "$f" 2>/dev/null | od -An -t x1 | tr -d ' \n' | grep -qi '^7f454c46' && printf 'ELF executable/library\n' && return
    head -c 4 "$f" 2>/dev/null | od -An -t x1 | tr -d ' \n' | grep -qi '^cafebabe' && printf 'Fat/Mach-O (fat?)\n' && return
    head -c 4 "$f" 2>/dev/null | od -An -t x1 | tr -d ' \n' | grep -qi '^feedface\|^feedfacf\|^cefaedfe' && printf 'Mach-O\n' && return
    head -c 2 "$f" 2>/dev/null | grep -q '^#!' && printf 'Script (#!)\n' && return
    printf 'Unknown binary/text\n'
  else
    printf 'Not readable\n'
  fi
}

# Try to read ELF info via readelf/objdump or nm where available
inspect_elf() {
  f="$1"
  if have readelf; then
    readelf -h "$f" 2>/dev/null | sed -n '1,10p'
    readelf -a "$f" 2>/dev/null | sed -n '1,100p'
    return
  fi
  if have objdump; then
    objdump -f "$f" 2>/dev/null | sed -n '1,20p'
    return
  fi
  if have llvm-readobj; then
    llvm-readobj --file-headers "$f" 2>/dev/null || :
    return
  fi
  # minimal fallback: strings for interpreter
  if have strings; then
    strings "$f" 2>/dev/null | egrep -m1 -i 'GLIBC|ld-linux|ld64|/lib/|/lib64/|libgcc_s|libstdc\+\+|libc\.' || :
  fi
}

# Try to read Mach-O info via otool/llvm tools on macOS
inspect_macho() {
  f="$1"
  if have otool; then
    otool -h "$f" 2>/dev/null || :
    otool -L "$f" 2>/dev/null || :
    return
  fi
  if have llvm-readobj; then
    llvm-readobj --macho-header "$f" 2>/dev/null || :
    return
  fi
  if have strings; then
    strings "$f" 2>/dev/null | egrep -m1 -i 'libSystem|@executable_path|@rpath|libgcc_s' || :
  fi
}

# Portable small timeout: run a command and kill if it exceeds N seconds.
# Usage: run_with_timeout SECONDS command args...
run_with_timeout() {
  secs="$1"; shift
  cmd="$@"
  # Prefer coreutils timeout if available
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" $cmd
    return $?
  fi
  # macOS gtimeout
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" $cmd
    return $?
  fi
  # Fallback: background + kill
  sh -c "$cmd" >/dev/null 2>&1 &
  pid=$!
  # wait up to $secs seconds
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  return 0
}

# Heuristic: skip executing binaries that look interactive or wrappers that might block
looks_blocking_or_interactive() {
  f="$1"
  # If it's a script, look for 'read ' or 'readline' etc
  if head -n 20 "$f" 2>/dev/null | grep -qE '^[[:space:]]*read[[:space:]]+-'; then
    return 0
  fi
  if strings "$f" 2>/dev/null | egrep -qi 'readline|press any key|press enter|interactive|stdin|tty' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Safer version guessing: only execute known-safe command names or use timeout
guess_version() {
  f="$1"
  name="$(basename "$f")"

  # If file isn't executable, try strings only
  [ -x "$f" ] || {
    if have strings; then
      strings "$f" 2>/dev/null | egrep -m1 -i 'GCC|clang version|LLVM|GNU|FreeBSD|Apple clang|GNU Fortran|icc|version' || true
    fi
    return
  }

  # Known safe names we can exec
  case "$name" in
    gcc|g\+\+|cc|clang|clang\+\+|ld|ld.lld|lld|as|ar|ranlib|nm|objdump|readelf|gfortran|rustc|cargo|ld64|otool)
      run_with_timeout 5 "$f" --version 2>/dev/null && return
      run_with_timeout 5 "$f" -v 2>/dev/null && return
      ;;
    *)
      # If looks interactive or may block, don't execute; fall back to strings.
      if looks_blocking_or_interactive "$f"; then
        if have strings; then
          strings "$f" 2>/dev/null | egrep -m1 -i 'GCC|clang version|LLVM|GNU|FreeBSD|Apple clang|GNU Fortran|icc|version' || true
        fi
        return
      fi

      # Try a guarded --version with timeout
      run_with_timeout 5 "$f" --version 2>/dev/null && return
      run_with_timeout 5 "$f" -v 2>/dev/null && return
      run_with_timeout 5 "$f" -V 2>/dev/null && return
      ;;
  esac

  # fallback to strings-based guess if execution didn't return anything
  if have strings; then
    strings "$f" 2>/dev/null | egrep -m1 -i 'GCC|clang version|LLVM|GNU|FreeBSD|Apple clang|GNU Fortran|icc' || true
  fi
}

# Guess roles based on file name, ELF SONAMEs, exported symbols, and strings
guess_roles() {
  f="$1"
  name="$(basename "$f")"
  roles=""
  case "$name" in
    gcc|gcc-*|*gcc-*)
      roles="${roles}C-compiler "
      ;;
    cc|cc-*)
      roles="${roles}C-compiler "
      ;;
    g++|g++-*|*g++*|*c++*|clang++)
      roles="${roles}C++-compiler "
      ;;
    tcc|tcc-*)
      roles="${roles}C-compiler TCC-impl "
      ;;
    gfortran|f95|flang|g77|f90|gfortran-*)
      roles="${roles}Fortran-compiler "
      ;;
    clang|clang-*)
      roles="${roles}C/C++-compiler "
      ;;
    javac)
      roles="${roles}Java-compiler "
      ;;
    *ld*|*ld.bfd*|*ld.gold*|*lld*)
      roles="${roles}Linker "
      ;;
    *gold*)
      roles="${roles}Linker(gold) "
      ;;
    *lld*)
      roles="${roles}Linker(lld) "
      ;;
    *as|*as86|*as-arm*|*gcc-as)
      roles="${roles}Assembler "
      ;;
    *ar|*ranlib)
      roles="${roles}Archiver/ranlib "
      ;;
    *nm|*nm-*)
      roles="${roles}Symbol-inspector "
      ;;
    *objcopy|*objcopy-*)
      roles="${roles}Object-copy "
      ;;
    *objdump|*readelf|*llvm-objdump|*llvm-readobj)
      roles="${roles}Object-inspector "
      ;;
    *strip)
      roles="${roles}Stripper "
      ;;
    *ld64*|*ld64.lld*|*dsymutil)
      roles="${roles}Mac-linker/symbolizer "
      ;;
    *otool|*lipo)
      roles="${roles}Mac-inspector "
      ;;
    ninja|ninja-build)
      roles="${roles}Build-orchestrator "
      ;;
    make|gmake|make-*|mingw32-make)
      roles="${roles}Build-orchestrator "
      ;;
    meson|bazel|scons)
      roles="${roles}Build-orchestrator "
      ;;
    *ccache|*sccache)
      roles="${roles}Compiler-cache "
      ;;
    ccmake|cmake)
      roles="${roles}CMake-frontend "
      ;;
    *rustc|*cargo|*riscv*|*clang-tidy)
      roles="${roles}Other-compiler/tool "
      ;;
    curl|curl-*|wget|wget-*|fetch|fetch-*)
      roles="${roles}Network-fetcher "
      ;;
    nc|nc-?|netcat)
      roles="${roles}Network-fetcher "
      ;;
    python|python2|python2.*|python3|python3.*|pypy|pypy3|pypy3.*|pypy.*|jython|cython|rustpython)
      roles="${roles}Python-runtime "
      ;;
    perl|perl5|perl-*)
      roles="${roles}Perl-runtime "
      ;;
    sh|bash|dash|ksh|zsh|ash|rbash)
      roles="${roles}Shell "
      ;;
    git|git-*|hg|mercurial|bzr|bzr-*|svn|svn-*)
      roles="${roles}VCS "
      ;;
    hq|hq-*|fossil|fossil-*|darcs)
      roles="${roles}VCS "
      ;;
    *.so|*.dylib|*.a)
      roles="${roles}Library "
      ;;
  esac

  # content-based hints
 # content-based hints (only run if `strings` is available)
  if have strings; then
    # C runtime hints
    if strings "$f" 2>/dev/null | grep -q -e 'GCC:' -e 'gcc version' -e 'libgcc_s'; then
      case "$roles" in *C-compiler*) : ;; *) roles="${roles}C-runtime ";; esac
    fi

    # Rust runtime
    if strings "$f" 2>/dev/null | grep -qi 'Rust'; then
      roles="${roles}Rust-runtime "
    fi

    # lld linker detection
    if strings "$f" 2>/dev/null | grep -q 'ld.lld'; then
      roles="${roles}Linker(lld) "
    fi

    # Network fetcher hints
    if strings "$f" 2>/dev/null | grep -qi -e 'curl' -e 'wget' -e 'libcurl' -e 'NET::HTTP' -e 'libssl' -e 'OpenSSL' -e 'LibreSSL' -e 'HTTP/' -e 'netcat' -e 'nc '; then
      case "$roles" in *Network-fetcher*) : ;; *) roles="${roles}Network-fetcher ";; esac
    fi

    # BusyBox/toybox packing
    if strings "$f" 2>/dev/null | grep -qi -e 'BusyBox' -e 'toybox'; then
      case "$roles" in *Network-fetcher*) : ;; *) roles="${roles}Network-fetcher ";; esac
    fi

    # Java detection
    if strings "$f" 2>/dev/null | grep -q -e 'javac' -e 'Java VM' -e 'java version' -e 'OpenJDK'; then
      case "$roles" in *Java-compiler*) : ;; *) roles="${roles}Java-runtime/tool ";; esac
    fi

    # TCC detection
    if strings "$f" 2>/dev/null | grep -q -e 'TinyCC' -e 'tcc version'; then
      case "$roles" in *TCC-impl*) : ;; *) roles="${roles}TCC-impl ";; esac
    fi

    # Python runtime hints
    if strings "$f" 2>/dev/null | grep -qi -e 'Python' -e 'Py_Initialize' -e 'cpython' -e 'pypy' -e 'MicroPython' -e 'Jython'; then
      case "$roles" in *Python-runtime*) : ;; *) roles="${roles}Python-runtime ";; esac
    fi

    # Perl hint
    if strings "$f" 2>/dev/null | grep -qi 'perl'; then
      case "$roles" in *Perl-runtime*) : ;; *) roles="${roles}Perl-runtime ";; esac
    fi

    # Shell hint (look for shebangs or common shell strings)
    if strings "$f" 2>/dev/null | grep -qi -e '/bin/bash' -e '/bin/sh' -e 'ash' -e 'dash' -e 'ksh' -e 'zsh'; then
      case "$roles" in *Shell*) : ;; *) roles="${roles}Shell ";; esac
    fi

    # VCS hints
    if strings "$f" 2>/dev/null | grep -qi -e 'Git' -e 'Mercurial' -e 'Bazaar' -e 'Subversion' -e 'Fossil' -e 'darcs'; then
      case "$roles" in *VCS*) : ;; *) roles="${roles}VCS ";; esac
    fi

    # Build orchestrator hints
    if strings "$f" 2>/dev/null | grep -qi -e 'ninja' -e 'Makefile' -e 'GNU Make' -e 'meson' -e 'bazel' -e 'scons'; then
      case "$roles" in *Build-orchestrator*) : ;; *) roles="${roles}Build-orchestrator ";; esac
    fi
  fi

  [ -z "$roles" ] && roles="Unknown"
  printf '%s\n' "$roles"
}


# Detect if a file is a wrapper script (shell/perl/python) that calls other tools
detect_wrapper() {
  f="$1"
  if [ ! -r "$f" ]; then
    printf ''
    return
  fi
  # check shebang
  head -n 1 "$f" 2>/dev/null | grep -q '^#!' || {
    # binary, not wrapper
    printf ''
    return
  }
  # read first 50 lines to see invoked commands
  if have sed; then
    sed -n '1,200p' "$f" 2>/dev/null | egrep -i --line-number 'exec |system$|subprocess|gcc|clang|ccache|sccache|/usr/bin/' 2>/dev/null | sed -n '1,5p'
  else
    head -n 200 "$f" 2>/dev/null | egrep -i --line-number 'exec |system\(|subprocess|gcc|clang|ccache|sccache|/usr/bin/' 2>/dev/null | sed -n '1,5p'
  fi
}

# Try to find a target triple in filename or strings
guess_target_triplet() {
  f="$1"
  name="$(basename "$f")"

  # Try simple filename pattern: look for three '-' separated fields at start
  # Use case: x86_64-linux-gnu-gcc -> matches x86_64-linux-gnu
  # Portable sed: do not rely on $ $ capturing groups
  echo "$name" | sed -n 's/^$[a-z0-9_._+-]*-[a-z0-9_._+-]*-[a-z0-9_._+-]*$.*/\1/p' 2>/dev/null || true

  # Fallback: search in strings output for a likely triplet (use grep if available)
  if have strings; then
    if have grep; then
      strings "$f" 2>/dev/null | grep -iEo '[a-z0-9._+-]{2,30}-(linux|darwin|freebsd|mingw|w64)(-[a-z0-9._+-]{0,20})?' | head -n1 || true
    else
      # portable grep absent (very rare); try sed search
      strings "$f" 2>/dev/null | sed -n 's/.*$[a-z0-9._+-]\{2,30\}-\(linux\|darwin\|freebsd\|mingw\|w64$$-[a-z0-9._+-]\{0,20\}$\?\).*/\1/p' | head -n1 || true
    fi
  fi
}

# Inspect single candidate
inspect_candidate() {
  f="$1"
  print_header "$f"

  emit "Exists" "$( [ -e "$f" ] && printf 'yes' || printf 'no' )"
  emit "Executable" "$( [ -x "$f" ] && printf 'yes' || printf 'no' )"
  ft="$(detect_file_type "$f" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
  emit "FileType" "$ft"
  # Version guess
  ver="$(guess_version "$f" 2>/dev/null | sed -n '1,4p' | tr '\n' ' ' | sed 's/  */ /g')"
  [ -n "$ver" ] && emit "VersionGuess" "$ver"
  # Roles
  roles="$(guess_roles "$f")"
  emit "GuessedRoles" "$roles"
  # Target triplet
  tgt="$(guess_target_triplet "$f" | tr '\n' ' ' | sed 's/  */ /g')"
  [ -n "$tgt" ] && emit "TargetTripletHints" "$tgt"
  # Is it a wrapper script?
  if head -n1 "$f" 2>/dev/null | grep -q '^#!'; then
    emit "Wrapper" "yes (shebang)"
    detect_wrapper "$f" | sed -n '1,5p' | while IFS= read -r l; do [ -n "$l" ] && emit "WrapperLine" "$l"; done
  else
    emit "Wrapper" "no"
  fi

  # Deeper inspection
  case "$ft" in
    *ELF*)
      emit "Format" "ELF"
      inspect_elf "$f" 2>/dev/null | sed -n '1,60p' | while IFS= read -r l; do [ -n "$l" ] && emit "ELF" "$l"; done
      ;;
    *Mach-O*|*Mach-*|*fat*)
      emit "Format" "Mach-O/fat"
      inspect_macho "$f" 2>/dev/null | sed -n '1,60p' | while IFS= read -r l; do [ -n "$l" ] && emit "MachO" "$l"; done
      ;;
    *)
      # fallback minimal binary / script content scan for referenced libs and strings
      if have strings; then
        strings "$f" 2>/dev/null | egrep -m10 -i 'libstdc\+\+|libgcc_s|GLIBC|ld-linux|crt|crt1|crti|crtn|libSystem|@executable_path|ld64' | while IFS= read -r l; do [ -n "$l" ] && emit "Hint" "$l"; done
      fi
      ;;
  esac

  # If it's a static library or archive (.a), list members if ar available
  case "$f" in
    *.a)
      if have ar; then
        emit "ArchiveMembers" "$(ar -t "$f" 2>/dev/null | sed -n '1,20p' | tr '\n' ',' )"
      fi
      ;;
  esac

  # For dynamic libs (.so/.dylib) try to show soname or install name
  case "$f" in
    *.so* )
      if have readelf; then
        readelf -d "$f" 2>/dev/null | sed -n '1,20p' | while IFS= read -r l; do [ -n "$l" ] && emit "Dyn" "$l"; done
      fi
      ;;
    *.dylib )
      if have otool; then
        otool -D "$f" 2>/dev/null | sed -n '1,10p' | while IFS= read -r l; do [ -n "$l" ] && emit "Dyn" "$l"; done
      fi
      ;;
  esac

  # Show linked libraries (ldd or otool -L) if available
  if have ldd && [ -x "$f" ]; then
    ldd "$f" 2>/dev/null | sed -n '1,20p' | while IFS= read -r l; do [ -n "$l" ] && emit "Linked" "$l"; done
  elif have otool && [ -x "$f" ]; then
    otool -L "$f" 2>/dev/null | sed -n '1,20p' | while IFS= read -r l; do [ -n "$l" ] && emit "Linked" "$l"; done
  fi

  # If nm available, show exported symbols (first matches)
  if have nm; then
    nm -D --defined-only "$f" 2>/dev/null | sed -n '1,20p' | while IFS= read -r l; do [ -n "$l" ] && emit "ExportSym" "$l"; done
  fi

  # Print blank line marker
  printf '\n' >>"$OUT"
}

# --- Candidate discovery ---
# Build search list from PATH and EXTRA_DIRS
build_search_list() {
  search_dirs=""
  # PATH entries
  IFS=':'; for p in $PATH; do
    case "$search_dirs" in "" ) search_dirs="$p" ;; *) search_dirs="$search_dirs $p" ;; esac
  done; unset IFS
  for d in $EXTRA_DIRS; do
    case "$search_dirs" in *"$d"*) : ;; *) search_dirs="$search_dirs $d" ;; esac
  done
  printf '%s\n' "$search_dirs"
}

# Collect candidates by name heuristics + all executables in search dirs (but keep list limited)
collect_candidates() {
  max_execs=600
  found=0
  # search common names first (fast)
  for name in $COMMON_NAMES; do
    # look for exact match in PATH via command -v
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name" 2>/dev/null | while IFS= read -r p; do
        printf '%s\n' "$p"
      done
    fi
  done

  # Then scan search dirs for likely toolchain names (prefix/suffix)
  for d in $(build_search_list); do
    [ -d "$d" ] || continue
    # list limited entries
    ls -1A "$d" 2>/dev/null | egrep -i 'gcc|clang|ld|lld|as$|ar$|ranlib|nm|objdump|readelf|objcopy|objcopy-|strip|gfortran|flang|rustc|cargo|ccache|sccache|ld64|otool|darwin' 2>/dev/null | while IFS= read -r nm; do
      p="$d/$nm"
      [ -e "$p" ] || continue
      printf '%s\n' "$p"
    done
    # also include all executables up to a reasonable count
    if [ "$found" -lt "$max_execs" ]; then
      # find executables in dir; portable 'find' may not be present, use simple loop
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        [ -x "$f" ] || continue
        case "$f" in *.so|*.dylib|*.a) ;; *) printf '%s\n' "$f" ;; esac
        found=$((found + 1))
        [ "$found" -ge "$max_execs" ] && break
      done
    fi
  done
}

# --- Main ---
main() {
  printf 'Toolchain inspector run: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$OUT"
  printf 'Detected PATH: %s\n\n' "$PATH" >>"$OUT"

  # Identify platform
  uname_out="$(uname -s 2>/dev/null || echo unknown)"
  emit "Platform" "$uname_out"

  # Candidate list
  candidates_tmp="$(mktemp 2>/dev/null || printf '/tmp/inspect_toolchain_cands.$')"
  collect_candidates | sort -u >"$candidates_tmp" 2>/dev/null

  # If no candidates, try to fallback to checking compilers like cc, gcc, clang via command -v
  if [ ! -s "$candidates_tmp" ]; then
    for cc in cc gcc clang c++; do
      if command -v "$cc" >/dev/null 2>&1; then
        command -v "$cc" >>"$candidates_tmp" 2>/dev/null
      fi
    done
  fi

  # Iterate candidates
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    inspect_candidate "$candidate"
  done <"$candidates_tmp"

  rm -f "$candidates_tmp" 2>/dev/null || true
  printf 'Inspection complete\n' >>"$OUT"
}

main "$@"
