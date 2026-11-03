#!/usr/bin/env bash
# Build an iOS arm64 NMSSH XCFramework using libssh2 1.11.1 and OpenSSL 3.5.7.
# No precompiled SSH engines are used; dependencies are compiled on GitHub's macOS runner.
set -euo pipefail

ROOT="$(pwd)"
OUT="$ROOT/modern-ssh-build"
JOBS="$(sysctl -n hw.logicalcpu)"
JOBS="$(( JOBS > 4 ? 4 : JOBS ))"
mkdir -p "$OUT/sources" "$OUT/install"
echo "Xcode:"; xcodebuild -version
echo "Target: iOS arm64 | libssh2 1.11.1 | OpenSSL 3.5.7"

curl -fLSs --retry 3 --retry-delay 2 \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz \
  -o "$OUT/sources/openssl.tar.gz"
curl -fLSs --retry 3 --retry-delay 2 \
  https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz \
  -o "$OUT/sources/libssh2.tar.gz"

# Record immutable inputs so reviewers can verify what was compiled.
shasum -a 256 "$OUT/sources/"*.tar.gz
tar -xzf "$OUT/sources/openssl.tar.gz" -C "$OUT/sources"
tar -xzf "$OUT/sources/libssh2.tar.gz" -C "$OUT/sources"

OPENSSL_PREFIX="$OUT/install/openssl"
LIBSSH_PREFIX="$OUT/install/libssh2"
mkdir -p "$OPENSSL_PREFIX" "$LIBSSH_PREFIX"

echo "== Compile OpenSSL 3.5.7 for iOS =="
pushd "$OUT/sources/openssl-3.5.7" >/dev/null
./Configure ios64-xcrun \
  no-shared no-module no-tests no-apps no-asm \
  -miphoneos-version-min=15.0 \
  --prefix="$OPENSSL_PREFIX" \
  --openssldir="$OPENSSL_PREFIX/ssl"
make -j "$JOBS" build_sw
make install_sw
popd >/dev/null
test -s "$OPENSSL_PREFIX/lib/libcrypto.a"
test -s "$OPENSSL_PREFIX/lib/libssl.a"

echo "== Compile libssh2 1.11.1 for iOS =="
cmake -S "$OUT/sources/libssh2-1.11.1" -B "$OUT/libssh2-cmake" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$LIBSSH_PREFIX" \
  -DCRYPTO_BACKEND=OpenSSL \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF \
  -DENABLE_ZLIB_COMPRESSION=OFF
cmake --build "$OUT/libssh2-cmake" -j "$JOBS"
cmake --install "$OUT/libssh2-cmake"
test -s "$LIBSSH_PREFIX/lib/libssh2.a"

echo "== Package local CSSH dependency (static, no unsigned embedded dylibs) =="
CSSH="$OUT/CSSHLocal"
mkdir -p "$CSSH/Headers"
cp "$LIBSSH_PREFIX/include/libssh2.h" "$CSSH/Headers/"
cp "$LIBSSH_PREFIX/include/libssh2_sftp.h" "$CSSH/Headers/"
cp "$LIBSSH_PREFIX/include/libssh2_publickey.h" "$CSSH/Headers/"
cat > "$CSSH/Headers/module.modulemap" <<'MODULE'
module CSSH {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    export *
}
MODULE
/usr/bin/libtool -static -o "$OUT/libCSSH.a" \
  "$LIBSSH_PREFIX/lib/libssh2.a" \
  "$OPENSSL_PREFIX/lib/libssl.a" \
  "$OPENSSL_PREFIX/lib/libcrypto.a"
xcodebuild -create-xcframework \
  -library "$OUT/libCSSH.a" \
  -headers "$CSSH/Headers" \
  -output "$CSSH/CSSH.xcframework"
cat > "$CSSH/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CSSH",
    products: [.library(name: "CSSH", targets: ["CSSH"])],
    targets: [.binaryTarget(name: "CSSH", path: "CSSH.xcframework")]
)
PACKAGE

echo "== Build NMSSH using our own CSSH package =="
git clone -q https://github.com/thebaselab/NMSSH.git "$OUT/NMSSH"
git -C "$OUT/NMSSH" checkout --detach 68d4728ba2e284c587fa62bbfb349b5d43a05109
python3 - "$OUT/NMSSH/NMSSH-iOS.xcodeproj/project.pbxproj" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
old='''\t\t94A96C8F2982E56900F34EB2 /* XCRemoteSwiftPackageReference "Libssh2Prebuild" */ = {
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/DimaRU/Libssh2Prebuild";
\t\t\trequirement = {
\t\t\t\tbranch = master;
\t\t\t\tkind = branch;
\t\t\t};
\t\t};'''
new='''\t\t94A96C8F2982E56900F34EB2 /* XCRemoteSwiftPackageReference "Libssh2Prebuild" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "../CSSHLocal";
\t\t};'''
assert s.count(old)==1,"Could not find NMSSH package reference to replace"
p.write_text(s.replace(old,new,1))
PY
rm -f "$OUT/NMSSH/NMSSH-iOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
xcodebuild -resolvePackageDependencies \
  -project "$OUT/NMSSH/NMSSH-iOS.xcodeproj" \
  -scheme NMSSH
xcodebuild \
  -project "$OUT/NMSSH/NMSSH-iOS.xcodeproj" \
  -scheme NMSSH \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/NMSSHDerived" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

FRAMEWORK="$OUT/NMSSHDerived/Build/Products/Release-iphoneos/NMSSH.framework"
test -s "$FRAMEWORK/NMSSH"
echo "== Verify framework binary version =="
file "$FRAMEWORK/NMSSH"
# Materialize strings before grepping: -q would SIGPIPE macOS strings under pipefail.
strings "$FRAMEWORK/NMSSH" > "$OUT/nmssh-binary-strings.txt"
if ! grep -Fx '1.11.1' "$OUT/nmssh-binary-strings.txt"; then
  echo "ERROR: New libssh2 1.11.1 version marker not found in framework" >&2
  exit 1
fi
# Static linking may eliminate unused OpenSSL version strings; verify
# the compiled headers and linked cryptography symbols instead.
grep -F 'OPENSSL_VERSION_STR "3.5.7"' "$OPENSSL_PREFIX/include/openssl/opensslv.h"
nm -g "$FRAMEWORK/NMSSH" > "$OUT/nmssh-binary-symbols.txt"
grep -E '_EVP_(Digest|Cipher|PKEY)|_OPENSSL_init_crypto' "$OUT/nmssh-binary-symbols.txt" > "$OUT/openssl-linked-symbols.txt" || true
if [ ! -s "$OUT/openssl-linked-symbols.txt" ]; then
  echo "ERROR: No OpenSSL cryptography symbols linked into NMSSH" >&2
  exit 1
fi
sed -n '1,8p' "$OUT/openssl-linked-symbols.txt"

echo "== Create modern iOS-only NMSSH.xcframework =="
mkdir -p "$ROOT/modern-nmssh"
xcodebuild -create-xcframework \
  -framework "$FRAMEWORK" \
  -output "$ROOT/modern-nmssh/NMSSH.xcframework"
plutil -lint "$ROOT/modern-nmssh/NMSSH.xcframework/Info.plist"
du -sh "$ROOT/modern-nmssh/NMSSH.xcframework"
echo "SUCCESS: built NMSSH from libssh2 1.11.1 and OpenSSL 3.5.7"
