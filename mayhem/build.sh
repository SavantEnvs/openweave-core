#!/usr/bin/env bash
#
# mayhem/build.sh — build openweave-core's six upstream libFuzzer harnesses
# (src/test-apps/fuzz/Fuzz*) + standalone reproducers + the upstream test suite
# (src/test-apps check programs, run by mayhem/test.sh).
#
# The build contract comes from the base image (ghcr.io/mayhemheroes/base):
# CC/CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, STANDALONE_FUZZ_MAIN, SRC.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# The fuzzed code (libWeave, vendored openssl, the harnesses) is built with the FULL
# $SANITIZER_FLAGS (ASan + UBSan, -fno-sanitize-recover) from the base image. An explicit
# empty --build-arg SANITIZER_FLAGS= builds with no sanitizers.
FUZZ_SAN="$SANITIZER_FLAGS"

# --- 1) fetch third_party deps (network needed FIRST build only; no-op offline rerun) ---
if [ ! -f third_party/nlio/repo/include/nlbyteorder.h ]; then
  make -f Makefile-bootstrap
fi

# --- transient source fixups for modern clang/glib (idempotent; applied at build time,
#     kept out of the additive commit like the historical OSS-Fuzz patch.diff) ---
if ! grep -q '#include <glib.h>' src/platform/ble/bluez/BluezHelperCode.h; then
  sed -i 's|^extern "C" {|#include <glib.h>\n#include <dbus/dbus.h>\nextern "C" {|' \
    src/platform/ble/bluez/BluezHelperCode.h
fi
if [ -f third_party/bluez/repo/obexd/client/sync.c ] && \
   grep -q 'static struct obc_driver sync = {' third_party/bluez/repo/obexd/client/sync.c; then
  sed -i 's/static struct obc_driver sync = {/static struct obc_driver sync_driver = {/;
          s/obc_driver_register(&sync)/obc_driver_register(\&sync_driver)/;
          s/obc_driver_unregister(&sync)/obc_driver_unregister(\&sync_driver)/' \
    third_party/bluez/repo/obexd/client/sync.c
fi

for f in third_party/bluez/repo/tools/l2test.c third_party/bluez/repo/tools/rctest.c; do
  if [ -f "$f" ] && ! grep -q 'linux/sockios.h' "$f"; then
    sed -i 's|#include <sys/socket.h>|#include <sys/socket.h>\n#include <linux/sockios.h>|;
            s|#include <sys/stat.h>|#include <sys/stat.h>\n#include <linux/sockios.h>|' "$f"
  fi
done

CONFIGURE_OPTS="--disable-java --enable-fuzzing --disable-shared --disable-docs \
    --disable-warnings-as-errors \
    --disable-obex --disable-cups --disable-monitor --disable-client \
    --disable-systemd --disable-udev --disable-a2dp --disable-avrcp \
    --disable-network --disable-hid --disable-hog --disable-health \
    --disable-sap --disable-mesh --disable-midi"
[ -x configure ] || ./bootstrap

# Two OUT-OF-TREE (VPATH) builds under the gitignored .build/, from the one source tree:
#   .build/tests  the upstream test suite, project's normal flags (no sanitizers), so
#                 test.sh checks functional behaviour, not sanitizer findings;
#   .build/fuzz   the fuzz targets + the libWeave/OpenSSL code they link, full $SANITIZER_FLAGS.
# The source tree itself is never configured: autoconf refuses a VPATH configure of a
# source dir (incl. the fetched third_party/*/repo checkouts) that is configured in place.

# --- 2) upstream test suite (test.sh only RUNS these) ---
TESTBUILD="$SRC/.build/tests"
mkdir -p "$TESTBUILD"
if [ ! -f "$TESTBUILD/config.status" ]; then
  ( cd "$TESTBUILD" && "$SRC/configure" CC="$CC" CXX="$CXX" \
      CFLAGS="-O1 $DEBUG_FLAGS -Wno-unused-but-set-variable $COVERAGE_FLAGS" \
      CXXFLAGS="-O1 $DEBUG_FLAGS -Wno-unused-but-set-variable $COVERAGE_FLAGS" \
      LDFLAGS="-Wl,--allow-multiple-definition" $CONFIGURE_OPTS )
fi
make -C "$TESTBUILD" -j"$MAYHEM_JOBS"
make -C "$TESTBUILD/src/test-apps" -j"$MAYHEM_JOBS" check TESTS=

# --- 3) fuzz build with the full $SANITIZER_FLAGS (libFuzzer from --enable-fuzzing +
#     $LIB_FUZZING_ENGINE).
# -Wl,--allow-multiple-definition: the PASE harnesses deliberately define a deterministic
# RAND_bytes that must override vendored openssl's (first definition, the harness, wins).
#
# UBSan relax, vendored OpenSSL 1.1.0e ONLY: -fno-sanitize=function. OpenSSL calls its
# typed callbacks through generic pointer types, which the `function` check halts on for
# every FuzzCertificateConversion seed (6/6), before any harness logic runs:
#   crypto/lhash/lhash.c:274:12: runtime error: call to function err_string_data_hash
#   through pointer to incorrect function type 'unsigned long (*)(const void *)'
# It is passed through the (empty) WEAVE_OPENSSL_ENABLE_OPTIONS hook into OpenSSL's own
# ./Configure, so it lands after $SANITIZER_FLAGS on OpenSSL's compile lines only. libWeave,
# the harnesses, ASan and every other UBSan check stay on and halting.
OPENSSL_UBSAN_RELAX=""
case " $FUZZ_SAN " in *undefined*|*function*) OPENSSL_UBSAN_RELAX="-fno-sanitize=function" ;; esac
FUZZBUILD="$SRC/.build/fuzz"
mkdir -p "$FUZZBUILD"
if [ ! -f "$FUZZBUILD/config.status" ]; then
  ( cd "$FUZZBUILD" && "$SRC/configure" CC="$CC" CXX="$CXX" \
      CFLAGS="-O1 $FUZZ_SAN -fsanitize=fuzzer-no-link $DEBUG_FLAGS -Wno-unused-but-set-variable" \
      CXXFLAGS="-O1 $FUZZ_SAN -fsanitize=fuzzer-no-link $DEBUG_FLAGS -Wno-unused-but-set-variable" \
      LDFLAGS="-Wl,--allow-multiple-definition" $CONFIGURE_OPTS )
fi
make -C "$FUZZBUILD" -j"$MAYHEM_JOBS" WEAVE_OPENSSL_ENABLE_OPTIONS="$OPENSSL_UBSAN_RELAX"

# --- 4) stage fuzzers + corpora, and link standalone reproducers ---
FB="$FUZZBUILD"
FUZZDIR="$FB/src/test-apps/fuzz"
LINKLIBS="$FUZZDIR/libFuzzUtil.a $FB/src/tools/weave/libWeaveTool.a \
  $FB/src/test-apps/libWeaveTestCommon.a $FB/src/lib/libWeave.a \
  $FB/src/platform/ble/bluez/libWoBluez.a \
  $FB/third_party/bluez/repo/gdbus/.libs/libgdbus-internal.a \
  $FB/third_party/bluez/repo/src/.libs/libshared-glib.a"
LINKFLAGS="-L$FB/third_party/openssl/x86_64-pc-linux-gnu \
  -L$FB/third_party/nlunit-test/repo/src -L$FB/third_party/nlfaultinjection/repo/src \
  $(pkg-config --libs glib-2.0 dbus-1) -ldl -lrt -lcrypto -lnlunit-test -lnlfaultinjection -pthread"

$CC $FUZZ_SAN $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# Build-time LSan off (see mayhem/lsan_off.cc), linked into every fuzz + standalone binary.
$CXX $FUZZ_SAN $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o

for t in FuzzCertificateConversion FuzzPASEInitiatorStep1 FuzzPASEInitiatorStep2 \
         FuzzPASEKeyConfirm FuzzPASEResponderStep1 FuzzPASEResponderStep2; do
  # Relink the upstream-compiled harness object (rather than copying upstream's binary)
  # so the LSan hook is linked in; same libs, $LIB_FUZZING_ENGINE supplies libFuzzer.
  $CXX -O1 $FUZZ_SAN $DEBUG_FLAGS $LIB_FUZZING_ENGINE -std=gnu++11 -fno-exceptions \
    -Wl,--allow-multiple-definition "$FUZZDIR/$t.o" /tmp/lsan_off.o \
    $LINKLIBS $LINKFLAGS -o "/mayhem/$t"
  $CXX -O1 $FUZZ_SAN $DEBUG_FLAGS -std=gnu++11 -fno-exceptions \
    -Wl,--allow-multiple-definition "$FUZZDIR/$t.o" /tmp/standalone_main.o /tmp/lsan_off.o \
    $LINKLIBS $LINKFLAGS -o "/mayhem/$t-standalone"
done
