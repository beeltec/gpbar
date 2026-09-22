#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export GPBAR_REQUIRE_OPENCONNECT=1
export PKG_CONFIG_PATH="$project_root/build/native/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CARGO_TARGET_DIR="$project_root/build/engine"
krb5_prefix=$(brew --prefix krb5)
fixture=$(mktemp -d "$project_root/build/kerberos-fixture.XXXXXX")
kdc_pid=''
server_pid=''
cleanup() {
    for pid in "$server_pid" "$kdc_pid"; do
        if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
    rm -rf -- "$fixture"
}
trap cleanup EXIT HUP INT TERM
export KRB5_CONFIG="$fixture/krb5.conf"
export KRB5_KDC_PROFILE="$fixture/kdc.conf"
export KRB5CCNAME="FILE:$fixture/tickets"
export KRB5_KTNAME="FILE:$fixture/server.keytab"
kdc_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat > "$KRB5_CONFIG" <<CONF
[libdefaults]
 default_realm = GPBAR.TEST
 dns_lookup_kdc = false
 dns_lookup_realm = false
 dns_canonicalize_hostname = false
 rdns = false
[realms]
 GPBAR.TEST = {
  kdc = 127.0.0.1:$kdc_port
 }
[domain_realm]
 .gpbar.test = GPBAR.TEST
CONF
cat > "$KRB5_KDC_PROFILE" <<CONF
[kdcdefaults]
 kdc_listen = 127.0.0.1:$kdc_port
 kdc_tcp_listen = 127.0.0.1:$kdc_port
[realms]
 GPBAR.TEST = {
  database_name = $fixture/principal
  key_stash_file = $fixture/stash
  acl_file = $fixture/acl
 }
CONF
printf 'fixture-master\nfixture-master\n' | "$krb5_prefix/sbin/kdb5_util" create -s > "$fixture/setup.log" 2>&1
for principal in alice HTTP/portal.gpbar.test HTTP/gateway.gpbar.test; do
    "$krb5_prefix/sbin/kadmin.local" -q "addprinc -randkey $principal" >> "$fixture/setup.log" 2>&1
done
"$krb5_prefix/sbin/kadmin.local" -q "ktadd -k $fixture/client.keytab alice" >> "$fixture/setup.log" 2>&1
"$krb5_prefix/sbin/kadmin.local" -q "ktadd -k $fixture/server.keytab HTTP/portal.gpbar.test HTTP/gateway.gpbar.test" >> "$fixture/setup.log" 2>&1
"$krb5_prefix/sbin/krb5kdc" -n > "$fixture/kdc.log" 2>&1 &
kdc_pid=$!
sleep 1
"$krb5_prefix/bin/kinit" -k -t "$fixture/client.keytab" alice
clang -Wall -Wextra -Werror -I"$krb5_prefix/include" -L"$krb5_prefix/lib" -lgssapi_krb5 Tests/Kerberos/accept.c -o "$fixture/accept"
swiftc -swift-version 6 -parse-as-library -framework GSS Shared/*.swift GPBar/Services/KerberosSession.swift Tests/Kerberos/Native.swift -o "$fixture/native"
"$fixture/native" "$fixture/accept"
KRB5CCNAME="FILE:$fixture/missing-tickets" "$fixture/native" --missing
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost' -addext 'basicConstraints=critical,CA:FALSE' \
    -keyout "$fixture/key.pem" -out "$fixture/cert.pem" > "$fixture/openssl.log" 2>&1
python3 Tests/Kerberos/server.py "$fixture" > "$fixture/server.log" 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5; do
    if [ -f "$fixture/origin" ]; then break; fi
    sleep 1
done
GPBAR_KERBEROS_TEST_ORIGIN=$(cat "$fixture/origin")
export GPBAR_KERBEROS_TEST_ORIGIN
export GPBAR_KERBEROS_TEST_CERT="$fixture/cert.pem"
(cd Vendor/openprotect && cargo test --locked -p gp-auth kerberos_ -- --include-ignored && cargo test --locked -p opc kerberos_)
