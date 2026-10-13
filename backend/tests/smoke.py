"""End-to-end local chat API smoke test. Run after `dotnet build backend/src/Chat.Api`."""

import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
DLL = ROOT / "src/Chat.Api/bin/Debug/net10.0/Chat.Api.dll"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class SignalRSocket:
    """Small WebSocket client for one SignalR JSON protocol event assertion."""

    def __init__(self, port, connection_token, access_token):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        path = f"/hubs/chat?id={quote(connection_token)}&access_token={quote(access_token)}"
        request = (
            f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.socket.sendall(request.encode())
        headers = bytearray()
        while b"\r\n\r\n" not in headers:
            headers.extend(self.socket.recv(1))
        if b" 101 " not in headers.split(b"\r\n", 1)[0]:
            raise AssertionError(headers.decode(errors="replace"))
        self.send_text('{"protocol":"json","version":1}\x1e')
        if self.next_record() != {}:
            raise AssertionError("SignalR protocol handshake failed")

    def close(self):
        self.socket.close()

    def send_text(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            prefix = bytes([0x81, 0x80 | length])
        elif length <= 65535:
            prefix = bytes([0x81, 0x80 | 126]) + length.to_bytes(2, "big")
        else:
            raise ValueError("Test frame too large")
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.socket.sendall(prefix + mask + masked)

    def receive_exact(self, count):
        chunks = bytearray()
        while len(chunks) < count:
            chunk = self.socket.recv(count - len(chunks))
            if not chunk:
                raise ConnectionError("WebSocket closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def next_record(self):
        while True:
            first, second = self.receive_exact(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = int.from_bytes(self.receive_exact(2), "big")
            elif length == 127:
                length = int.from_bytes(self.receive_exact(8), "big")
            payload = self.receive_exact(length)
            if opcode == 8:
                raise ConnectionError("WebSocket closed by server")
            if opcode != 1:
                continue
            return json.loads(payload.decode().rstrip("\x1e"))


class ChatApiSmokeTest(unittest.TestCase):
    def setUp(self):
        if not DLL.exists():
            self.fail(f"Build the API first: dotnet build {ROOT / 'src/Chat.Api'}")
        self.temp = tempfile.TemporaryDirectory(prefix="chat-api-test-")
        self.log = open(Path(self.temp.name) / "server.log", "w+")
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.server = None
        self.start_server()

    def tearDown(self):
        self.stop_server()
        self.log.close()
        self.temp.cleanup()

    def start_server(self):
        env = os.environ.copy()
        env.update({
            "ASPNETCORE_ENVIRONMENT": "Development",
            "DOTNET_ENVIRONMENT": "Development",
            "ASPNETCORE_URLS": self.base,
            "Chat__DataPath": str(Path(self.temp.name) / "chat-state.json"),
        })
        self.server = subprocess.Popen(
            ["dotnet", str(DLL)], cwd=ROOT / "src/Chat.Api", env=env,
            stdout=self.log, stderr=subprocess.STDOUT,
        )
        for _ in range(100):
            if self.server.poll() is not None:
                self.log.seek(0)
                self.fail("API exited during startup:\n" + self.log.read())
            try:
                if self.request("GET", "/health")[0] == 200:
                    return
            except URLError:
                pass
            time.sleep(0.1)
        self.fail("API did not become ready")

    def stop_server(self):
        if self.server is not None and self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=5)

    def request(self, method, path, body=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else None
        request = Request(self.base + path, data=data, headers=headers, method=method)
        try:
            response = urlopen(request, timeout=5)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None

    def test_two_account_chat_and_restart(self):
        suffix = uuid4().hex[:8]
        _, alice = self.request("POST", "/api/auth/register", {
            "displayName": "Alice", "email": f"alice-{suffix}@example.com",
            "password": "alice-pass-123",
        })
        _, bob = self.request("POST", "/api/auth/register", {
            "displayName": "Bob", "email": f"bob-{suffix}@example.com",
            "password": "bob-pass-123",
        })
        _, stranger = self.request("POST", "/api/auth/register", {
            "displayName": "Stranger", "email": f"stranger-{suffix}@example.com",
            "password": "stranger-pass-123",
        })
        a, b, outsider = alice["accessToken"], bob["accessToken"], stranger["accessToken"]
        self.assertEqual(self.request("GET", "/openapi/v1.json")[1]["openapi"], "3.1.0")
        self.assertEqual(self.request("POST", "/hubs/chat/negotiate?negotiateVersion=1")[0], 401)
        self.assertEqual(self.request("POST", "/hubs/chat/negotiate?negotiateVersion=1", token=a)[0], 200)
        status, bob_negotiation = self.request(
            "POST", "/hubs/chat/negotiate?negotiateVersion=1", token=b)
        self.assertEqual(status, 200)
        self.assertEqual(self.request("GET", "/api/auth/me", token=a)[1]["id"], alice["user"]["id"])
        self.assertEqual(self.request("GET", "/api/auth/me", token=a + "x")[0], 401)
        self.assertEqual(self.request("GET", "/api/users?query=Bob", token=a)[1][0]["id"], bob["user"]["id"])
        self.assertEqual(self.request("POST", "/api/auth/login", {
            "email": alice["user"]["email"], "password": "wrong-password",
        })[0], 401)

        create = {"peerUserId": bob["user"]["id"]}
        status, conversation = self.request("POST", "/api/conversations", create, a)
        self.assertEqual(status, 201)
        cid = conversation["id"]
        self.assertEqual(self.request("POST", "/api/conversations", create, a)[1]["id"], cid)
        self.assertEqual(self.request("GET", f"/api/conversations/{cid}/messages", token=outsider)[0], 404)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "intrusion",
        }, outsider)[0], 404)
        status, error = self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "  ",
        }, a)
        self.assertEqual((status, error["code"]), (400, "validation_error"))

        first_payload = {"clientMessageId": str(uuid4()), "text": "Xin chào!"}
        realtime = SignalRSocket(self.port, bob_negotiation["connectionToken"], b)
        try:
            time.sleep(0.1)  # Let OnConnectedAsync add Bob to his private user group.
            status, first = self.request("POST", f"/api/conversations/{cid}/messages", first_payload, a)
            event = realtime.next_record()
            self.assertEqual(event["target"], "MessageCreated")
            self.assertEqual(event["arguments"][0]["id"], first["id"])
        finally:
            realtime.close()
        self.assertEqual(status, 201)
        self.assertEqual(first["sequence"], 1)
        status, duplicate = self.request("POST", f"/api/conversations/{cid}/messages", first_payload, a)
        self.assertEqual((status, duplicate["id"]), (200, first["id"]))
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", {
            **first_payload, "text": "changed",
        }, a)[0], 409)

        _, second = self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "Chào Alice!",
        }, b)
        self.assertEqual(second["sequence"], 2)
        page = self.request("GET", f"/api/conversations/{cid}/messages?limit=1", token=a)[1]
        self.assertEqual([item["sequence"] for item in page["items"]], [2])
        self.assertEqual(page["nextCursor"], 2)
        older = self.request("GET", f"/api/conversations/{cid}/messages?limit=1&beforeSequence=2", token=a)[1]
        self.assertEqual([item["sequence"] for item in older["items"]], [1])
        self.assertIsNone(older["nextCursor"])
        self.assertEqual(self.request("GET", "/api/conversations", token=a)[1][0]["unreadCount"], 1)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/read", {
            "throughSequence": 2,
        }, a)[1]["lastReadSequence"], 2)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/read", {
            "throughSequence": 1,
        }, a)[1]["lastReadSequence"], 2)
        self.assertEqual(self.request("GET", "/api/conversations", token=a)[1][0]["unreadCount"], 0)
        self.assertEqual(self.request("GET", "/api/conversations", token=b)[1][0]["peerLastReadSequence"], 2)

        status, rotated = self.request("POST", "/api/auth/refresh", {
            "refreshToken": alice["refreshToken"],
        })
        self.assertEqual(status, 200)
        self.assertNotEqual(rotated["refreshToken"], alice["refreshToken"])
        self.assertEqual(self.request("POST", "/api/auth/refresh", {
            "refreshToken": alice["refreshToken"],
        })[0], 401)
        self.assertEqual(self.request("GET", "/api/auth/me", token=rotated["accessToken"])[0], 200)

        self.stop_server()
        self.start_server()
        status, login = self.request("POST", "/api/auth/login", {
            "email": alice["user"]["email"], "password": "alice-pass-123",
        })
        self.assertEqual(status, 200)
        history = self.request("GET", f"/api/conversations/{cid}/messages", token=login["accessToken"])[1]
        self.assertEqual([item["sequence"] for item in history["items"]], [2, 1])


if __name__ == "__main__":
    unittest.main()
