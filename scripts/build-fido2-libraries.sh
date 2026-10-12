#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
cmake="$root/build/tools/cmake/data/bin/cmake"
# Downloaded archives must match the pinned provenance before building.
python3 scripts/fetch-fido2-sources.py
for arch in arm64 x86_64; do
  prefix="$root/build/fido-$arch/prefix"
  mkdir -p "$root/build/fido-$arch/openssl" "$prefix"
  if [ ! -f "$prefix/lib/libcrypto.a" ]; then
  (
    cd "$root/build/fido-$arch/openssl"
    perl "$root/build/fido-sources/openssl-4.0.3/Configure" "darwin64-$arch-cc" no-shared no-tests no-apps no-docs no-dso no-module no-autoload-config no-sock no-dgram --prefix="$prefix" -mmacosx-version-min=12.4
    make -j8 build_libs
    make install_dev
  )
  fi
  "$cmake" -S build/fido-sources/libcbor-0.14.0 -B "build/fido-$arch/cbor" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.4 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWITH_EXAMPLES=OFF
  "$cmake" --build "build/fido-$arch/cbor" -j8
  "$cmake" --install "build/fido-$arch/cbor"
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  cat > "$prefix/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: macOS SDK zlib
Version: 1.2.12
Libs: -lz
Cflags: -I$sdk/usr/include
PC
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" "$cmake" -S build/fido-sources/libfido2-1.17.0 -B "build/fido-$arch/fido" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.4 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_MANPAGES=OFF -DUSE_PCSC=OFF -DHAVE_ZLIB_H=1 -DZLIB_LIBRARIES=z -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=TRUE
  "$cmake" --build "build/fido-$arch/fido" -j8
  "$cmake" --install "build/fido-$arch/fido"
done
for lib in libcrypto.a libcbor.a libfido2.a; do
  lipo -create "build/fido-arm64/prefix/lib/$lib" "build/fido-x86_64/prefix/lib/$lib" -output "Vendor/FIDO2/lib/$lib"
done

cp build/fido-arm64/prefix/include/fido.h Vendor/FIDO2/include/
cp -R build/fido-arm64/prefix/include/fido/. Vendor/FIDO2/include/fido/
cp -R build/fido-arm64/prefix/include/openssl/. Vendor/FIDO2/include/openssl/
