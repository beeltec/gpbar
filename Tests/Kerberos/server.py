#!/usr/bin/env python3
"""Synthetic GlobalProtect Kerberos handoff; no real VPN tunnel."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64
import ssl
import sys
from urllib.parse import parse_qs, urlsplit


def encoded(value):
    return base64.b64encode(value.encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, code, body='', headers=()):
        payload = body.encode()
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 262144:
            self.reply(413)
            return
        params = parse_qs(self.rfile.read(size).decode(), keep_blank_values=True)
        path = urlsplit(self.path).path
        mode = params.get('host-id', ['success'])[0]
        gateway = path.startswith('/ssl-vpn/')
        side = 'gateway' if gateway else 'portal'
        cookie = f'{side}+handoff/=='
        authorization = self.headers.get('Authorization')
        if path.endswith('/prelogin.esp'):
            fallback = params.get('kerberos-support') == ['no']
            if fallback:
                if mode not in ('missing', 'reject', 'failed-status', 'initial-failure') or authorization:
                    self.reply(403)
                else:
                    self.reply(200, '<prelogin-response><status>Success</status><password-label>Password</password-label></prelogin-response>')
                return
            if mode == 'http-error':
                self.reply(503)
                return
            if mode == 'redirect':
                self.reply(302, headers=[('Location', 'https://127.0.0.1:1/never')])
                return
            if not authorization:
                if mode == 'initial-failure':
                    self.reply(200, '<prelogin-response><status>Success</status><krb-auth-status>0</krb-auth-status></prelogin-response>')
                elif mode == 'empty-status':
                    self.reply(200, '<prelogin-response><status>Success</status><krb-auth-status/></prelogin-response>')
                elif mode == 'unsolicited':
                    self.reply(200, f'<prelogin-response><status>Success</status><krb-auth-status>1</krb-auth-status><krb-norm-username>alice</krb-norm-username><prelogin-cookie>{cookie}</prelogin-cookie></prelogin-response>')
                else:
                    value = 'Negotiate ' + ('!' if mode == 'bad-header' else '')
                    self.reply(401, headers=[('WWW-Authenticate', value)])
                return
            if authorization != 'Negotiate ' + encoded(f'{side}-ticket'):
                self.reply(403)
                return
            if mode == 'invalid-continuation':
                self.reply(401, headers=[('WWW-Authenticate', 'Negotiate ' + encoded('invalid'))])
                return
            if mode == 'reject':
                self.reply(401, headers=[('WWW-Authenticate', 'Negotiate')])
                return
            fields = '<krb-auth-status>1</krb-auth-status><krb-norm-username>alice</krb-norm-username>'
            if mode == 'missing-status':
                fields = ''
            if mode == 'failed-status':
                fields = '<krb-auth-status>0</krb-auth-status>'
            if mode != 'missing-cookie':
                fields += f'<prelogin-cookie>{cookie}</prelogin-cookie>'
            headers = [] if mode == 'missing-mutual' else [('WWW-Authenticate', 'Negotiate ' + encoded(f'{side}-reply'))]
            self.reply(200, f'<prelogin-response><status>Success</status>{fields}</prelogin-response>', headers)
            return
        if authorization or params.get('user') != ['alice'] or params.get('passwd') != [''] or params.get('prelogin-cookie') != [cookie]:
            self.reply(403)
            return
        if path == '/global-protect/getconfig.esp':
            self.reply(200, '<policy><agent-config><krb-auth-fail-fallback>yes</krb-auth-fail-fallback></agent-config><gateways><external><list><entry name="gateway.example"/></list></external></gateways></policy>')
        elif path == '/ssl-vpn/login.esp':
            self.reply(200, '<jnlp><application-desc><argument>fixture-authcookie</argument><argument>persistent</argument><argument>portal</argument><argument>alice</argument><argument>domain</argument><argument>0</argument><argument>0</argument><argument></argument><argument>10.0.0.1</argument><argument></argument><argument></argument><argument></argument><argument>0</argument></application-desc></jnlp>')
        else:
            self.reply(404)


directory = Path(sys.argv[1])
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(directory / 'cert.pem', directory / 'key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
(directory / 'origin').write_text(f'https://localhost:{server.server_port}')
server.serve_forever()
