#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive="$project_root/build/openconnect-9.21.tar.gz"
mkdir -p "$project_root/build"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz -o "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != 5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58 ]; then
    echo 'OpenConnect source checksum does not match.' >&2
    exit 1
fi
native_work=$(mktemp -d "$project_root/build/native-work.XXXXXX")
trap 'rm -rf -- "$native_work"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$native_work"
cd "$native_work/openconnect-9.21"
patch -p1 < "$project_root/Packaging/Patches/openconnect-private-hip.patch"
export MACOSX_DEPLOYMENT_TARGET=26.0
./configure --prefix="$project_root/build/native" --enable-shared --disable-static --disable-nls \
    --without-libproxy --without-stoken --without-libpcsclite --without-libpskc --without-gssapi \
    --without-gnutls-tss2 --with-vpnc-script=/nonexistent/gpbar-script --with-system-cafile=/etc/ssl/cert.pem
make -j8
make install
