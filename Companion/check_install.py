"""Offline checks for installed dependencies, certificate pairing and HTTP auth."""
import hashlib
import http.client
import inspect
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from pyicloud import PyiCloudService
from pyicloud.services.findmyiphone import AppleDevice, FindMyiPhoneServiceManager
from life360 import Life360
from companion import certificate, handler_for
from http.server import ThreadingHTTPServer


class InstalledCompanionTests(unittest.TestCase):
    def test_connector_interfaces_match_pinned_packages(self):
        self.assertIn("authenticate", inspect.signature(PyiCloudService).parameters)
        self.assertIn("locate", inspect.signature(FindMyiPhoneServiceManager.refresh).parameters)
        self.assertIsInstance(AppleDevice.location, property)
        self.assertIn("max_retries", inspect.signature(Life360).parameters)
        self.assertIn("mid", inspect.signature(Life360.get_circle_member).parameters)

    def test_tls_certificate_pin_and_authenticated_read_only_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            cert, key, fingerprint = certificate(Path(directory), "127.0.0.1")
            parsed = x509.load_pem_x509_certificate(cert.read_bytes())
            actual = hashlib.sha256(parsed.public_bytes(serialization.Encoding.DER)).hexdigest()
            self.assertEqual(actual, fingerprint)
            token = "a" * 64
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(token, []))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            client_context = ssl.create_default_context(cafile=str(cert))
            def request(method, path, header=None):
                connection = http.client.HTTPSConnection("127.0.0.1", server.server_port, context=client_context, timeout=3)
                try:
                    connection.request(method, path, headers={} if header is None else {"Authorization": header})
                    response = connection.getresponse()
                    return response.status, response.read()
                finally:
                    connection.close()
            try:
                self.assertEqual(request("GET", "/reports")[0], 401)
                self.assertEqual(request("GET", "/reports", "Bearer wrong")[0], 401)
                status, body = request("GET", "/reports", "Bearer " + token)
                self.assertEqual(status, 200)
                report = json.loads(body)["reports"][0]
                self.assertEqual(report["provider"], "findmy-person")
                self.assertEqual(report["state"], "unavailable")
                self.assertIsNone(report["latitude"])
                self.assertEqual(request("GET", "/anything", "Bearer " + token)[0], 404)
                self.assertEqual(request("POST", "/reports", "Bearer " + token)[0], 501)
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3)


if __name__ == "__main__": unittest.main()
