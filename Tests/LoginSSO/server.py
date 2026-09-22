#!/usr/bin/env python3
"""Synthetic password portal with one MFA challenge; no tunnel or real credentials."""
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
        if size > 262144:
            self.send_error(413)
            return
        params = parse_qs(self.rfile.read(size).decode(), keep_blank_values=True)
        if self.path.endswith('/prelogin.esp'):
            body = '<prelogin-response><status>Success</status><password-label>Password</password-label></prelogin-response>'
        elif self.path != '/global-protect/getconfig.esp' or params.get('user') != ['fixture-user']:
            self.send_error(403)
            return
        elif params.get('passwd') == ['fixture+password&='] and not params.get('inputStr'):
            body = '<challenge><inputstr>fixture-challenge</inputstr><respmsg>Enter your code</respmsg></challenge>'
        elif params.get('passwd') == ['123456'] and params.get('inputStr') == ['fixture-challenge']:
            body = '<policy><gateways><external><list><entry name="gateway.example"/></list></external></gateways></policy>'
        else:
            self.send_error(403)
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
context.load_cert_chain(directory / 'cert.pem', directory / 'key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
(directory / 'origin').write_text(f'https://localhost:{server.server_port}')
server.serve_forever()
