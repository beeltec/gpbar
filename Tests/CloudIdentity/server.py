#!/usr/bin/env python3
"""Synthetic CAS portal and gateway. No VPN tunnel or identity provider."""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
from urllib.parse import parse_qs


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 262144:
            self.send_error(413)
            return
        params = parse_qs(self.rfile.read(size).decode(), keep_blank_values=True)
        if self.path.endswith('/prelogin.esp'):
            body = '<prelogin-response><status>Success</status><cas-auth>yes</cas-auth><saml-auth-method>POST</saml-auth-method><saml-request>'
            body += base64.b64encode(b'<form method="post" action="https://cie.example/authorize"><input name="request" value="synthetic-signed-request"></form>').decode()
            body += '</saml-request></prelogin-response>'
        elif params.get('token') != ['fixture+opaque/token=='] or params.get('user') != ['alice@example.com']:
            self.send_error(403)
            return
        elif any(params.get(key) != [''] for key in ('passwd', 'prelogin-cookie', 'portal-userauthcookie')):
            self.send_error(400)
            return
        elif self.path == '/global-protect/getconfig.esp':
            body = '<policy><gateways><external><list><entry name="gateway.example"/></list></external></gateways></policy>'
        elif self.path == '/ssl-vpn/login.esp':
            body = '<jnlp><application-desc>' + ''.join(f'<argument>{value}</argument>' for value in (
                '0', 'fixture-tunnel-cookie', '2', 'portal.example', 'alice@example.com', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '')) + '</application-desc></jnlp>'
        else:
            self.send_error(404)
            return
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/xml')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.directory / 'cert.pem', args.directory / 'key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    (args.directory / 'origin').write_text(f'https://localhost:{server.server_port}')
    server.serve_forever()
