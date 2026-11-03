import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import kindle_sync_server as srv  # noqa: E402


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.httpd, self.store, _ = srv.build_server("127.0.0.1", 0, self.tmp.name, admin_password="secret-pw")
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, auth=None, headers=None, raw=False):
        data = json.dumps(body).encode() if body is not None and not raw else body
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Accept", "application/vnd.koreader.v1+json")
        if body is not None and not raw:
            req.add_header("Content-Type", "application/json")
        if auth:
            req.add_header("x-auth-user", auth[0])
            req.add_header("x-auth-key", auth[1])
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req) as resp:
                return resp.status, resp.read(), resp.headers
        except urllib.error.HTTPError as err:
            return err.code, err.read(), err.headers

    def jrequest(self, *args, **kwargs):
        status, body, _ = self.request(*args, **kwargs)
        return status, (json.loads(body) if body else None)

    def pair(self, device_id, name):
        code, _ = self.store.create_pair_code(srv.OWNER)
        status, body = self.jrequest(
            "POST", "/v1/pair", {"code": code.lower(), "device_id": device_id, "device_name": name, "device_model": "Test"}
        )
        self.assertEqual(status, 200, body)
        return body["username"], body["userkey"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class TestKosyncCompatibility(ServerTestCase):
    def test_healthcheck(self):
        self.assertEqual(self.jrequest("GET", "/healthcheck"), (200, {"state": "OK", "version": srv.SERVER_VERSION}))

    def test_stock_client_logs_in_with_md5_of_dashboard_password(self):
        key = hashlib.md5(b"secret-pw").hexdigest()
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=("reader", key))[0], 200)
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=("reader", "nope"))[0], 401)

    def test_registration_closed_by_default(self):
        status, body = self.jrequest("POST", "/users/create", {"username": "a", "password": "b"})
        self.assertEqual(status, 402)
        self.assertEqual(body["code"], "registration_closed")

    def test_put_then_get_progress(self):
        auth = self.pair("dev-a", "Kindle")
        status, body = self.jrequest(
            "PUT",
            "/syncs/progress",
            {"document": "hash1", "progress": "/body/p[3]", "percentage": 0.25, "device": "Kindle", "device_id": "dev-a"},
            auth=auth,
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["version"], 1)
        status, record = self.jrequest("GET", "/syncs/progress/hash1", auth=auth)
        self.assertEqual(status, 200)
        self.assertEqual(record["progress"], "/body/p[3]")
        self.assertAlmostEqual(record["percentage"], 0.25)
        self.assertEqual(record["device_id"], "dev-a")

    def test_unknown_document_returns_empty_object(self):
        auth = self.pair("dev-a", "Kindle")
        self.assertEqual(self.jrequest("GET", "/syncs/progress/nothing", auth=auth), (200, {}))

    def test_missing_fields_rejected(self):
        auth = self.pair("dev-a", "Kindle")
        status, body = self.jrequest("PUT", "/syncs/progress", {"document": "x"}, auth=auth)
        self.assertEqual(status, 403)
        self.assertEqual(body["code"], "invalid_fields")

    def test_bad_base_version_rejected(self):
        auth = self.pair("dev-a", "Kindle")
        body = {"document": "x", "progress": "1", "percentage": 0.1, "device": "Kindle", "base_version": "abc"}
        status, payload = self.jrequest("PUT", "/syncs/progress", body, auth=auth)
        self.assertEqual(status, 400)
        self.assertEqual(payload["code"], "invalid_fields")

    def test_bad_json_rejected(self):
        auth = self.pair("dev-a", "Kindle")
        status, _, _ = self.request("PUT", "/syncs/progress", b"{not json", auth=auth, raw=True)
        self.assertEqual(status, 400)


class TestCrossDevice(ServerTestCase):
    def test_book_key_links_different_files(self):
        kindle = self.pair("kindle", "Kindle")
        boox = self.pair("boox", "Boox Palma")
        self.jrequest(
            "PUT",
            "/syncs/progress",
            {"document": "kindle-epub-hash", "book_key": "dune|frank herbert", "progress": "/x", "percentage": 0.4,
             "device": "Kindle", "device_id": "kindle", "title": "Dune", "authors": "Frank Herbert"},
            auth=kindle,
        )
        # Boox has a different file but the same book_key.
        status, record = self.jrequest("GET", "/syncs/progress/dune%7Cfrank%20herbert", auth=boox)
        self.assertEqual(status, 200)
        self.assertAlmostEqual(record["percentage"], 0.4)
        self.assertEqual(record["document"], "kindle-epub-hash")
        # After Boox pushes with its own hash, its hash resolves to the shared book too.
        self.jrequest(
            "PUT",
            "/syncs/progress",
            {"document": "boox-hash", "book_key": "dune|frank herbert", "progress": "/y", "percentage": 0.5,
             "device": "Boox Palma", "device_id": "boox", "base_version": 1},
            auth=boox,
        )
        status, record = self.jrequest("GET", "/syncs/progress/kindle-epub-hash", auth=kindle)
        self.assertAlmostEqual(record["percentage"], 0.5)
        self.assertEqual(record["device"], "Boox Palma")
        self.assertEqual(record["version"], 2)

    def test_conflict_when_another_device_moved(self):
        kindle = self.pair("kindle", "Kindle")
        boox = self.pair("boox", "Boox")
        base = {"document": "h", "book_key": "k", "progress": "/a"}
        self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.1, device="Kindle", device_id="kindle"), auth=kindle)
        self.jrequest(
            "PUT", "/syncs/progress", dict(base, percentage=0.6, device="Boox", device_id="boox", base_version=1), auth=boox
        )
        # Kindle read offline from version 1 and now pushes 0.2.
        status, body = self.jrequest(
            "PUT", "/syncs/progress", dict(base, percentage=0.2, device="Kindle", device_id="kindle", base_version=1),
            auth=kindle,
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["code"], "conflict")
        self.assertAlmostEqual(body["current"]["percentage"], 0.6)
        # Explicit choice wins.
        status, body = self.jrequest(
            "PUT", "/syncs/progress",
            dict(base, percentage=0.2, device="Kindle", device_id="kindle", base_version=1, force=True), auth=kindle,
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["version"], 3)

    def test_same_device_never_conflicts_with_itself(self):
        kindle = self.pair("kindle", "Kindle")
        base = {"document": "h", "progress": "/a", "device": "Kindle", "device_id": "kindle"}
        self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.1), auth=kindle)
        self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.2), auth=kindle)
        status, _ = self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.3, base_version=1), auth=kindle)
        self.assertEqual(status, 200)

    def test_books_list_has_per_device_progress(self):
        kindle = self.pair("kindle", "Kindle")
        boox = self.pair("boox", "Boox")
        base = {"document": "h", "book_key": "k", "progress": "/a", "title": "Book"}
        self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.1, device="Kindle", device_id="kindle"), auth=kindle)
        self.jrequest("PUT", "/syncs/progress", dict(base, percentage=0.3, device="Boox", device_id="boox"), auth=boox)
        status, body = self.jrequest("GET", "/v1/books", auth=kindle)
        self.assertEqual(status, 200)
        book = body["books"][0]
        self.assertEqual(book["title"], "Book")
        self.assertEqual({d["device_id"] for d in book["devices"]}, {"kindle", "boox"})


class TestPairing(ServerTestCase):
    def test_bad_code(self):
        status, body = self.jrequest("POST", "/v1/pair", {"code": "ZZZZZZ"})
        self.assertEqual(status, 404)
        self.assertEqual(body["code"], "pair_code_invalid")

    def test_code_is_single_use(self):
        code, _ = self.store.create_pair_code(srv.OWNER)
        self.assertEqual(self.jrequest("POST", "/v1/pair", {"code": code, "device_id": "a"})[0], 200)
        self.assertEqual(self.jrequest("POST", "/v1/pair", {"code": code, "device_id": "b"})[0], 404)

    def test_removed_device_loses_access(self):
        auth = self.pair("dev", "Kindle")
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=auth)[0], 200)
        self.store.remove_device(srv.OWNER, "dev")
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=auth)[0], 401)


class TestDashboard(ServerTestCase):
    def login(self):
        status, _, headers = self.request("POST", "/login", b"password=secret-pw", raw=True)
        self.assertEqual(status, 303)
        return headers["Set-Cookie"].split(";")[0]

    def test_requires_login(self):
        status, body, _ = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"Sign in", body)

    def test_wrong_password(self):
        status, _, _ = self.request("POST", "/login", b"password=nope", raw=True)
        self.assertEqual(status, 401)

    def test_dashboard_and_pair_code(self):
        cookie = self.login()
        status, body, _ = self.request("GET", "/", headers={"Cookie": cookie})
        self.assertIn(b"No reading progress yet", body)
        csrf = body.split(b"name=csrf value=")[1].split(b">")[0].decode()
        status, _, _ = self.request("POST", "/pair", ("csrf=%s" % csrf).encode(), raw=True, headers={"Cookie": cookie})
        self.assertEqual(status, 303)
        self.assertEqual(len(self.store.active_pair_codes(srv.OWNER)), 1)
        # CSRF protection.
        status, _, _ = self.request("POST", "/pair", b"csrf=bad", raw=True, headers={"Cookie": cookie})
        self.assertEqual(status, 403)

    def test_titles_are_escaped(self):
        auth = self.pair("dev", "Kindle")
        self.jrequest(
            "PUT", "/syncs/progress",
            {"document": "h", "progress": "/a", "percentage": 0.5, "device": "K", "device_id": "dev",
             "title": "<script>x</script>"},
            auth=auth,
        )
        cookie = self.login()
        _, body, _ = self.request("GET", "/", headers={"Cookie": cookie})
        self.assertNotIn(b"<script>x", body)
        self.assertIn(b"&lt;script&gt;", body)


class TestBookKeyParity(unittest.TestCase):
    """Must match spec/cloud_sync_policy_spec.lua so Lua and Python agree."""

    def test_matches_lua_vectors(self):
        self.assertEqual(srv.book_key_for("Dune (Dune Chronicles, Book 1)", "Herbert, Frank"), "dune|frank herbert")
        self.assertEqual(srv.book_key_for("Dune", "Frank Herbert\nBrian Herbert"), "dune|frank herbert")
        self.assertEqual(srv.book_key_for("The Hobbit", "J.R.R. Tolkien"), srv.book_key_for("hobbit", "J R R Tolkien"))
        self.assertEqual(srv.book_key_for(None, None, "My_Book"), "file:my book")
        self.assertIsNone(srv.book_key_for("", None, ""))
        self.assertEqual(srv.book_key_for("Dune", ""), "dune")
        self.assertEqual(srv.book_key_for("Ender\u2019s Game", "Orson Scott Card"), "ender s game|orson scott card")
        self.assertEqual(srv.book_key_for("Ender's Game", "Card, Orson Scott"), "ender s game|orson scott card")
        self.assertEqual(srv.book_key_for("Wait\u00a0\u2014 for it\u2026", None), "wait for it")
        self.assertEqual(srv.book_key_for("Les Misérables [Kindle Edition]", "Hugo; Victor"), "les misérables|hugo")


class TestCrossPoint(ServerTestCase):
    """Flows as the Xteink X4 CrossPoint firmware performs them (lib/KOReaderSync)."""

    MD5_PW = hashlib.md5(b"secret-pw").hexdigest()

    def crosspoint(self, method, path, body=None):
        headers = {"Authorization": "Basic cmVhZGVyOnNlY3JldC1wdw=="}
        return self.jrequest(method, path, body, auth=("reader", self.MD5_PW), headers=headers)

    def kindle_push(self, percentage):
        kindle = self.pair("kindle", "Kindle")
        self.jrequest(
            "PUT", "/syncs/progress",
            {"document": "kindle-hash", "book_key": "dune|frank herbert", "progress": "/body/DocFragment[9]/p[4]",
             "percentage": percentage, "device": "Kindle", "device_id": "kindle", "title": "Dune",
             "authors": "Frank Herbert"},
            auth=kindle,
        )

    def test_unknown_document_is_404_for_crosspoint(self):
        status, body = self.crosspoint("GET", "/syncs/progress/x4hash?position_kinds=locator,percentage")
        self.assertEqual(status, 404)

    def test_metadata_links_x4_to_kindle_and_never_drags_progress_back(self):
        self.kindle_push(0.40)
        # First sync on the X4: unknown hash, Smart Sync uploads its 5%.
        status, _ = self.crosspoint(
            "PUT", "/syncs/progress",
            {"document": "x4hash", "progress": "/body/DocFragment[1]/p[2]", "percentage": 0.05,
             "device": "CrossPoint", "device_id": "x4",
             "metadata": {"filename": "Dune.epub", "title": "Dune (Dune 1)", "authors": "Frank Herbert"},
             "position": {"pctQ": 500, "spine": 1, "page": 2, "pages": 9}},
        )
        self.assertEqual(status, 200)
        # The Kindle's 40% stays the shared position.
        status, record = self.crosspoint("GET", "/syncs/progress/x4hash?position_kinds=locator,percentage")
        self.assertEqual(status, 200)
        self.assertAlmostEqual(record["percentage"], 0.40)
        # Different file: no XPointer into the wrong document, so it goes by percentage.
        self.assertEqual(record["progress"], "")
        self.assertNotIn("position", record)

    def test_x4_ahead_moves_everyone_forward(self):
        self.kindle_push(0.40)
        status, _ = self.crosspoint(
            "PUT", "/syncs/progress",
            {"document": "x4hash", "progress": "/body/DocFragment[20]/p[1]", "percentage": 0.55,
             "device": "CrossPoint", "device_id": "x4", "metadata": {"title": "Dune", "authors": "Frank Herbert"}},
        )
        self.assertEqual(status, 200)
        status, record = self.jrequest("GET", "/syncs/progress/dune%7Cfrank%20herbert", auth=("reader", self.MD5_PW))
        self.assertAlmostEqual(record["percentage"], 0.55)
        self.assertEqual(record["device"], "CrossPoint")

    def test_same_file_keeps_exact_position(self):
        status, _ = self.crosspoint(
            "PUT", "/syncs/progress",
            {"document": "samehash", "progress": "/body/DocFragment[3]/p[7]", "percentage": 0.2,
             "device": "CrossPoint", "device_id": "x4", "position": {"pctQ": 2000, "spine": 2, "page": 3, "pages": 10}},
        )
        self.assertEqual(status, 200)
        status, record = self.crosspoint("GET", "/syncs/progress/samehash?position_kinds=locator,percentage")
        self.assertEqual(record["progress"], "/body/DocFragment[3]/p[7]")
        self.assertEqual(record["position"]["spine"], 2)

    def test_later_syncs_from_same_device_can_go_back(self):
        self.kindle_push(0.40)
        body = {"document": "x4hash", "progress": "/p", "device": "CrossPoint", "device_id": "x4",
                "metadata": {"title": "Dune", "authors": "Frank Herbert"}}
        self.crosspoint("PUT", "/syncs/progress", dict(body, percentage=0.05))  # first sync: kept remote
        self.crosspoint("PUT", "/syncs/progress", dict(body, percentage=0.10))  # deliberate re-read later
        status, record = self.crosspoint("GET", "/syncs/progress/x4hash")
        self.assertAlmostEqual(record["percentage"], 0.10)


if __name__ == "__main__":
    unittest.main()


class TestThrottle(ServerTestCase):
    def test_wrong_keys_lock_the_client_out(self):
        auth = self.pair("dev", "Kindle")
        for _ in range(srv.MAX_FAILURES):
            self.assertEqual(self.jrequest("GET", "/users/auth", auth=(srv.OWNER, "wrong"))[0], 401)
        status, body = self.jrequest("GET", "/users/auth", auth=auth)
        self.assertEqual(status, 429)
        self.assertEqual(body["code"], "too_many_attempts")

    def test_pair_code_guessing_is_throttled(self):
        for _ in range(srv.MAX_FAILURES):
            self.assertEqual(self.jrequest("POST", "/v1/pair", {"code": "ZZZZZZ", "device_id": "x"})[0], 404)
        code, _ = self.store.create_pair_code(srv.OWNER)
        self.assertEqual(self.jrequest("POST", "/v1/pair", {"code": code, "device_id": "x"})[0], 429)

    def test_dashboard_login_is_throttled(self):
        for _ in range(srv.MAX_FAILURES):
            self.httpd.RequestHandlerClass.throttle.fail("127.0.0.1")
        status, body, _ = self.request("POST", "/login", b"password=secret-pw", raw=True)
        self.assertEqual(status, 429)
        self.assertIn(b"Too many failed attempts", body)

    def test_forwarded_client_is_counted_separately(self):
        auth = self.pair("dev", "Kindle")
        attacker = {"X-Forwarded-For": "203.0.113.9"}
        for _ in range(srv.MAX_FAILURES):
            self.request("GET", "/users/auth", auth=(srv.OWNER, "wrong"), headers=attacker)
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=(srv.OWNER, "wrong"), headers=attacker)[0], 429)
        self.assertEqual(self.jrequest("GET", "/users/auth", auth=auth)[0], 200)

    def test_successes_are_not_counted(self):
        auth = self.pair("dev", "Kindle")
        for _ in range(srv.MAX_FAILURES + 2):
            self.assertEqual(self.jrequest("GET", "/users/auth", auth=auth)[0], 200)
