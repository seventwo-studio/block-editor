"""Real local HTTP responses prove locked bytes, bounded repair and failed evidence."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("locked_download", Path(__file__).resolve().parents[1] / "scripts/locked_download.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class LockedDownloadTest(unittest.TestCase):
    def check_responses(self, responses, success, attempts):
        body = b"independent locked archive fixture"
        requests, delays = [], []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                requests.append(dict(self.headers))
                status, payload, headers = responses[min(len(requests) - 1, len(responses) - 1)]
                self.send_response(status); self.send_header("Content-Length", str(len(payload)))
                self.send_header("Content-Type", "application/octet-stream")
                for key, value in headers.items(): self.send_header(key, value)
                self.end_headers(); self.wfile.write(payload)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                target, evidence = Path(directory) / "archive.zip", Path(directory) / "evidence.jsonl"
                entry = {"url": f"http://127.0.0.1:{server.server_port}/archive", "size": len(body), "sha256": hashlib.sha256(body).hexdigest()}
                if success:
                    module.download(entry, target, "fixture", evidence, sleep=delays.append)
                    self.assertEqual(target.read_bytes(), body)
                else:
                    with self.assertRaises(RuntimeError): module.download(entry, target, "fixture", evidence, sleep=delays.append)
                    self.assertFalse(target.exists())
                receipts = [json.loads(line) for line in evidence.read_text().splitlines()]
                self.assertEqual(len(requests), attempts); self.assertEqual(len(receipts), attempts)
                self.assertTrue(all(row["expectedSHA256"] == entry["sha256"] and row["expectedBytes"] == len(body) for row in receipts))
                for row in receipts:
                    if row["rejectedFile"]:
                        rejected = Path(directory) / row["rejectedFile"]
                        self.assertEqual(hashlib.sha256(rejected.read_bytes()).hexdigest(), row["actualSHA256"])
                        self.assertEqual(rejected.stat().st_size, row["receivedBytes"])
                if attempts > 1: self.assertEqual(requests[1].get("Cache-Control"), "no-cache")
                return receipts, delays
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_exact_bytes_succeed_once(self):
        self.check_responses([(200, b"independent locked archive fixture", {})], True, 1)

    def test_short_body_retains_original_then_verifies_fresh_bytes(self):
        receipts, delays = self.check_responses([(200, b"short", {}), (200, b"independent locked archive fixture", {})], True, 2)
        self.assertEqual(delays, [2]); self.assertEqual(receipts[0]["receivedBytes"], 5)

    def test_unrequested_partial_response_never_counts_as_verified(self):
        receipts, _ = self.check_responses([(206, b"independent locked archive fixture", {"Content-Range": "bytes 0-32/33"}),
                                           (200, b"independent locked archive fixture", {})], True, 2)
        self.assertEqual(receipts[0]["outcome"], "rejected")

    def test_complete_wrong_hash_halts_without_retry(self):
        receipts, delays = self.check_responses([(200, b"x" * len(b"independent locked archive fixture"), {})], False, 1)
        self.assertFalse(receipts[0]["retryable"]); self.assertEqual(delays, [])

    def test_denied_access_halts_without_retry(self):
        receipts, delays = self.check_responses([(403, b"denied", {})], False, 1)
        self.assertEqual(receipts[0]["httpStatus"], 403); self.assertEqual(delays, [])

    def test_exhausted_transfer_repairs_preserve_every_attempt(self):
        receipts, delays = self.check_responses([(200, b"short", {})], False, 3)
        self.assertEqual(delays, [2, 5]); self.assertTrue(all(row["rejectedFile"] for row in receipts))


if __name__ == "__main__": unittest.main()
