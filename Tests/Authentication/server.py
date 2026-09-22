#!/usr/bin/env python3
"""Synthetic certificate and cookie endpoints, with required mutual TLS."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import sys
from urllib.parse import parse_qs


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 <= size <= 262144 or not self.connection.getpeercert():
            self.send_error(400)
            return
        params = parse_qs(self.rfile.read(size).decode(), keep_blank_values=True)
        if self.path in ['/global-protect/prelogin.esp', '/ssl-vpn/prelogin.esp']:
            body = '<prelogin-response><status>Success</status><authentication-message>Certificate accepted</authentication-message><ccusername>fixture-user</ccusername></prelogin-response>'
        elif self.path == '/global-protect/getconfig.esp':
            if params.get('user') != ['fixture-user'] or params.get('passwd') != ['']:
                self.send_error(403)
                return
            if params.get('portal-userauthcookie') not in [[''], ['portal+cookie&=']]:
                self.send_error(403)
                return
            body = '<policy><portal-userauthcookie>portal+cookie&amp;=</portal-userauthcookie><agent-config><save-user-credentials>1</save-user-credentials></agent-config><authentication-override><accept-cookie>yes</accept-cookie><generate-cookie>yes</generate-cookie><cookie-lifetime><lifetime-in-hours>1</lifetime-in-hours></cookie-lifetime></authentication-override><gateways><external><list><entry name="gateway.example"/></list></external></gateways></policy>'
        elif self.path == '/ssl-vpn/login.esp':
            if params.get('user') != ['fixture-user'] or params.get('portal-userauthcookie') != ['portal+cookie&=']:
                self.send_error(403)
                return
            if params.get('passwd') == [''] and not params.get('inputStr'):
                body = '<challenge><inputstr>gateway-state</inputstr><respmsg>Gateway code</respmsg></challenge>'
            elif params.get('passwd') == ['654321'] and params.get('inputStr') == ['gateway-state']:
                args = ['', 'tunnel-cookie', '', 'portal.example', 'fixture-user', '', '', 'fixture'] + [''] * 8 + ['gateway-cookie']
                body = '<jnlp><application-desc>' + ''.join(f'<argument>{arg}</argument>' for arg in args) + '</application-desc></jnlp>'
            else:
                self.send_error(403)
                return
        else:
            self.send_error(404)
            return
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/xml')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


directory = Path(sys.argv[1])
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(directory / 'server.pem', directory / 'server.key')
context.load_verify_locations(directory / 'clients.pem')
context.verify_mode = ssl.CERT_REQUIRED
server.socket = context.wrap_socket(server.socket, server_side=True)
(directory / 'origin').write_text(f'https://localhost:{server.server_port}')
server.serve_forever()
