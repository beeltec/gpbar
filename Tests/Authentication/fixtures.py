#!/usr/bin/env python3
"""Create disposable TLS identities. No certificates enter system trust."""
from pathlib import Path
import subprocess
import sys
import uuid


directory = Path(sys.argv[1])
(directory / 'cookie-origin').write_text(f'https://gpbar-fixture-{uuid.uuid4()}.invalid')
with (directory / 'openssl.log').open('w') as log:
    for name, key in [
        ('server', ['rsa:2048']),
        ('rsa', ['rsa:2048']),
        ('p256', ['ec', '-pkeyopt', 'ec_paramgen_curve:P-256']),
        ('p384', ['ec', '-pkeyopt', 'ec_paramgen_curve:P-384']),
        ('p521', ['ec', '-pkeyopt', 'ec_paramgen_curve:P-521']),
    ]:
        options = ['-addext', 'subjectAltName=DNS:localhost'] if name == 'server' else []
        subprocess.run([
            'openssl', 'req', '-x509', '-newkey', *key, '-nodes', '-days', '1',
            '-subj', f'/CN=GPBar fixture {name}', '-addext', 'basicConstraints=critical,CA:FALSE',
            '-addext', 'keyUsage=critical,digitalSignature', '-addext',
            'extendedKeyUsage=' + ('serverAuth' if name == 'server' else 'clientAuth'),
            *options, '-keyout', str(directory / f'{name}.key'), '-out', str(directory / f'{name}.pem'),
        ], check=True, stdout=log, stderr=log)
        subprocess.run([
            'openssl', 'x509', '-in', str(directory / f'{name}.pem'),
            '-outform', 'DER', '-out', str(directory / f'{name}.der'),
        ], check=True, stdout=log, stderr=log)
        if name != 'server':
            subprocess.run([
                'openssl', 'pkcs12', '-export', '-in', str(directory / f'{name}.pem'),
                '-inkey', str(directory / f'{name}.key'), '-out', str(directory / f'{name}.p12'),
                '-passout', 'pass:fixture', '-keypbe', 'PBE-SHA1-3DES',
                '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
            ], check=True, stdout=log, stderr=log)
(directory / 'clients.pem').write_bytes(b''.join(
    (directory / f'{name}.pem').read_bytes() for name in ['rsa', 'p256', 'p384', 'p521']
))
