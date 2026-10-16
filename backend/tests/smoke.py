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
DLL = ROOT / "src/Chat.Api/bin/Debug/net8.0/Chat.Api.dll"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class SignalRSocket:
    """Small WebSocket client for one SignalR JSON protocol event assertion."""

    def __init__(self, port, connection_token, access_token):
        self.pending_records = []
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
            if self.pending_records:
                return self.pending_records.pop(0)
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
            self.pending_records.extend(
                json.loads(record) for record in payload.decode().split("\x1e") if record
            )


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

    def voice_request(self, path, token, client_id, audio, duration_ms=1500, reply_id=None):
        boundary = 'voice-' + uuid4().hex
        fields = [
            ("clientMessageId", client_id.encode()),
            ("durationMs", str(duration_ms).encode()),
        ]
        if reply_id is not None:
            fields.append(("replyToMessageId", reply_id.encode()))
        body = bytearray()
        for name, value in fields:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(value + b'\r\n')
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="audio"; filename="voice.m4a"\r\nContent-Type: audio/mp4\r\n\r\n'.encode())
        body.extend(audio)
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        request = Request(self.base + path, data=bytes(body), headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "multipart/form-data; boundary=" + boundary,
        }, method="POST")
        try:
            response = urlopen(request, timeout=5)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None

    def test_update_profile_validation_and_persistence(self):
        suffix = uuid4().hex[:8]
        original_email = f"profile-alice-{suffix}@example.com"
        new_email = f"profile-updated-{suffix}@example.com"
        other_email = f"profile-bob-{suffix}@example.com"
        _, alice = self.request("POST", "/api/auth/register", {
            "displayName": "Alice", "email": original_email,
            "password": "profile-pass-123",
        })
        _, bob = self.request("POST", "/api/auth/register", {
            "displayName": "Bob", "email": other_email,
            "password": "profile-pass-123",
        })
        token = alice["accessToken"]

        self.assertEqual(self.request("PUT", "/api/auth/me", {
            "displayName": "Alice Updated", "email": new_email,
        })[0], 401)
        self.assertEqual(self.request("PUT", "/api/auth/me", {
            "displayName": " ", "email": new_email,
        }, token)[0], 400)
        self.assertEqual(self.request("PUT", "/api/auth/me", {
            "displayName": "Alice Updated", "email": other_email,
        }, token)[0], 409)
        self.assertEqual(self.request("GET", "/api/auth/me", token=token)[1]["email"],
                         original_email)

        status, updated = self.request("PUT", "/api/auth/me", {
            "displayName": "  Alice Updated  ", "email": f"  {new_email.upper()}  ",
        }, token)
        self.assertEqual(status, 200)
        self.assertEqual(updated, {
            "id": alice["user"]["id"],
            "displayName": "Alice Updated",
            "email": new_email,
            "avatarUrl": None,
        })
        self.assertEqual(self.request("GET", "/api/auth/me", token=token)[1], updated)
        self.assertEqual(self.request("GET", "/api/auth/me",
                                      token=bob["accessToken"])[1]["email"], other_email)
        self.assertEqual(self.request("POST", "/api/auth/login", {
            "email": original_email, "password": "profile-pass-123",
        })[0], 401)
        self.assertEqual(self.request("POST", "/api/auth/login", {
            "email": new_email, "password": "profile-pass-123",
        })[1]["user"], updated)

        self.stop_server()
        self.start_server()
        self.assertEqual(self.request("GET", "/api/auth/me", token=token)[1], updated)

    def profile_request(self, token, name, email, image=None, remove=False):
        boundary = "profile-" + uuid4().hex
        body = bytearray()
        for key, value in [("displayName", name), ("email", email), ("removeAvatar", str(remove).lower())]:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
        if image is not None:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="avatar"; filename="photo.png"\r\nContent-Type: image/png\r\n\r\n'.encode())
            body.extend(image + b"\r\n")
        body.extend(f'--{boundary}--\r\n'.encode())
        request = Request(self.base + "/api/auth/me/profile", data=bytes(body), headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "multipart/form-data; boundary=" + boundary,
        }, method="PUT")
        try:
            response = urlopen(request, timeout=10)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None

    def test_profile_avatar_atomic_update_access_restart_and_removal(self):
        suffix = uuid4().hex[:8]
        _, alice = self.request("POST", "/api/auth/register", {
            "displayName": "Alice", "email": f"avatar-a-{suffix}@example.com", "password": "avatar-pass-123",
        })
        _, bob = self.request("POST", "/api/auth/register", {
            "displayName": "Bob", "email": f"avatar-b-{suffix}@example.com", "password": "avatar-pass-123",
        })
        a, b = alice["accessToken"], bob["accessToken"]
        self.request("POST", "/api/conversations", {"peerUserId": bob["user"]["id"]}, a)
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQTr32HwAEKwJOk+jLUgAAAABJRU5ErkJggg==")
        email = alice["user"]["email"]
        self.assertEqual(self.profile_request("", "Alice", email, png)[0], 401)
        self.assertEqual(self.profile_request(a, " ", email, png)[0], 400)
        self.assertEqual(self.profile_request(a, "Alice", email, b"not-an-image")[0], 400)
        self.assertEqual(self.profile_request(a, "Alice", email, png + b"0" * 5_000_000)[0], 400)
        negotiation = self.request("POST", "/hubs/chat/negotiate?negotiateVersion=1", token=b)[1]
        realtime = SignalRSocket(self.port, negotiation["connectionToken"], b)
        try:
            time.sleep(0.1)
            status, updated = self.profile_request(a, "Alice Mới", email, png)
            self.assertEqual(status, 200)
            event = realtime.next_record()
            self.assertEqual(event["target"], "ConversationUpdated")
            self.assertEqual(event["arguments"][0]["peer"]["displayName"], "Alice Mới")
            self.assertEqual(event["arguments"][0]["peer"]["avatarUrl"], updated["avatarUrl"])
        finally:
            realtime.close()
        avatar_url = updated["avatarUrl"]
        self.assertEqual(self.request("GET", avatar_url)[0], 401)
        request = Request(self.base + avatar_url, headers={"Authorization": "Bearer " + b})
        with urlopen(request, timeout=5) as response:
            self.assertEqual(response.read(), png)
            self.assertEqual(response.headers["Content-Type"], "image/png")
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(self.request("GET", f"/api/users/{alice['user']['id']}", token=b)[1]["avatarUrl"], avatar_url)
        directory = Path(self.temp.name) / "avatars" / alice["user"]["id"].replace("-", "")
        self.assertEqual(len(list(directory.iterdir())), 1)
        self.assertEqual(self.profile_request(a, "Do not save", bob["user"]["email"], png)[0], 409)
        self.assertEqual(self.request("GET", "/api/auth/me", token=a)[1], updated)
        self.assertEqual(len(list(directory.iterdir())), 1)
        self.stop_server()
        self.start_server()
        self.assertEqual(self.request("GET", "/api/auth/me", token=a)[1], updated)
        self.assertEqual(self.request("POST", "/api/auth/login", {"email": email, "password": "avatar-pass-123"})[1]["user"]["avatarUrl"], avatar_url)
        _, replacement = self.profile_request(a, "Alice Mới", email, png)
        self.assertNotEqual(replacement["avatarUrl"], avatar_url)
        self.assertEqual(self.request("GET", avatar_url, token=b)[0], 404)
        self.assertEqual(len(list(directory.iterdir())), 1)
        status, removed = self.profile_request(a, "Alice Mới", email, remove=True)
        self.assertEqual(status, 200)
        self.assertIsNone(removed["avatarUrl"])
        self.assertEqual(self.request("GET", replacement["avatarUrl"], token=b)[0], 404)
        self.assertEqual(list(directory.iterdir()), [])
        self.assertIsNone(self.request("GET", "/api/auth/me", token=b)[1]["avatarUrl"])

    def attachment_request(self, path, token, client_id, data, name="report.pdf", kind="file", text="", reply_id=None):
        boundary = "attachment-" + uuid4().hex
        fields = [("clientMessageId", client_id), ("kind", kind), ("text", text)]
        if reply_id is not None:
            fields.append(("replyToMessageId", reply_id))
        body = bytearray()
        for key, value in fields:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode())
        body.extend(data)
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        request = Request(self.base + path, data=bytes(body), headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "multipart/form-data; boundary=" + boundary,
        }, method="POST")
        try:
            response = urlopen(request, timeout=10)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None

    def test_attachments_access_realtime_retry_restart_and_recall(self):
        suffix = uuid4().hex[:8]
        accounts = []
        for name in ("Alice", "Bob", "Stranger"):
            status, account = self.request("POST", "/api/auth/register", {
                "displayName": name, "email": f"attachment-{name}-{suffix}@example.com",
                "password": "attachment-pass-123",
            })
            self.assertEqual(status, 201)
            accounts.append(account)
        a, b, outsider = [account["accessToken"] for account in accounts]
        _, conversation = self.request("POST", "/api/conversations", {
            "peerUserId": accounts[1]["user"]["id"],
        }, a)
        cid = conversation["id"]
        path = f"/api/conversations/{cid}/attachments"
        data = b"%PDF-1.4 example report"
        client = str(uuid4())
        self.assertEqual(self.attachment_request(path, outsider, client, data)[0], 404)
        self.assertEqual(self.attachment_request(path, a, client, b"")[0], 400)
        self.assertEqual(self.attachment_request(path, a, client, data, kind="image")[0], 400)
        self.assertEqual(self.attachment_request(path, a, client, data, kind="text")[0], 400)
        self.assertEqual(self.attachment_request(path, a, client, b"a" * 20_000_001)[0], 400)
        negotiation = self.request("POST", "/hubs/chat/negotiate?negotiateVersion=1", token=b)[1]
        realtime = SignalRSocket(self.port, negotiation["connectionToken"], b)
        try:
            time.sleep(0.1)
            status, document = self.attachment_request(path, a, client, data, text="Report caption")
            self.assertEqual(status, 201)
            event = realtime.next_record()
            self.assertEqual(event["target"], "MessageCreated")
            self.assertEqual(event["arguments"][0]["attachment"]["name"], "report.pdf")
        finally:
            realtime.close()
        self.assertEqual(document["attachment"], {
            "name": "report.pdf", "size": len(data), "contentType": "application/octet-stream",
        })
        self.assertEqual(self.attachment_request(path, a, client, data, text="Report caption")[0], 200)
        self.assertEqual(self.attachment_request(path, a, client, data + b"changed", text="Report caption")[0], 409)
        self.assertEqual(self.attachment_request(path, a, client, data, text="changed")[0], 409)
        # PNG is detected from its bytes rather than the supplied MIME or filename.
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5wAAAABJRU5ErkJggg==")
        status, image = self.attachment_request(path, b, str(uuid4()), png,
            name="../photo.png", kind="image", reply_id=document["id"])
        self.assertEqual(status, 201)
        self.assertEqual(image["attachment"]["contentType"], "image/png")
        self.assertEqual(image["attachment"]["name"], "photo.png")
        self.assertEqual(image["replyTo"]["text"], "report.pdf")
        self.stop_server()
        self.start_server()
        for message, original in [(document, data), (image, png)]:
            download = f"/api/messages/{message['id']}/attachment"
            self.assertEqual(self.request("GET", download)[0], 401)
            self.assertEqual(self.request("GET", download, token=outsider)[0], 404)
            for token in (a, b):
                request = Request(self.base + download, headers={"Authorization": "Bearer " + token})
                with urlopen(request, timeout=5) as response:
                    self.assertEqual(response.read(), original)
                    self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            history = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]
            cached = next(item for item in history["items"] if item["id"] == message["id"])
            self.assertEqual(cached["attachment"], message["attachment"])
        self.assertEqual(self.request("PUT", f"/api/messages/{document['id']}/recall", token=b)[0], 403)
        status, recalled = self.request("PUT", f"/api/messages/{document['id']}/recall", token=a)
        self.assertEqual(status, 200)
        self.assertIsNone(recalled["attachment"])
        self.assertEqual(self.request("GET", f"/api/messages/{document['id']}/attachment", token=b)[0], 404)
        self.assertFalse((Path(self.temp.name) / "attachments" / document["id"].replace("-", "")).exists())

    def test_voice_message_upload_playback_and_access(self):
        suffix = uuid4().hex[:8]
        accounts = []
        for name in ("Alice", "Bob", "Stranger"):
            _, account = self.request("POST", "/api/auth/register", {
                "displayName": name,
                "email": f"voice-{name.lower()}-{suffix}@example.com",
                "password": "voice-pass-123",
            })
            accounts.append(account)
        alice, bob, stranger = accounts
        a, b, outsider = [account["accessToken"] for account in accounts]
        _, conversation = self.request("POST", "/api/conversations", {
            "peerUserId": bob["user"]["id"],
        }, a)
        cid = conversation["id"]
        _, original = self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "Tin gốc để trả lời",
        }, a)
        path = f"/api/conversations/{cid}/voice"
        client_id = str(uuid4())
        audio = b"\x00\x00\x00\x18ftypM4A " + b"test-voice-data"
        self.assertEqual(self.voice_request(path, outsider, client_id, audio)[0], 404)
        self.assertEqual(self.voice_request(path, a, client_id, b"not-an-m4a")[0], 400)
        status, voice = self.voice_request(path, a, client_id, audio,
                                           reply_id=original["id"])
        self.assertEqual(status, 201)
        self.assertEqual((voice["kind"], voice["voiceDurationMs"], voice["text"]),
                         ("voice", 1500, ""))
        self.assertEqual(voice["replyTo"]["id"], original["id"])
        self.assertEqual(voice["replyTo"]["text"], original["text"])
        self.assertEqual(self.voice_request(path, a, client_id, audio,
                                           reply_id=original["id"])[0], 200)
        self.assertEqual(self.voice_request(path, a, client_id, audio)[0], 409)
        self.assertEqual(self.voice_request(path, a, client_id, audio + b"changed")[0], 409)
        self.assertEqual(self.voice_request(path, a, str(uuid4()), audio, 121000)[0], 400)
        self.assertEqual(self.voice_request(path, a, str(uuid4()), audio + b"0" * 2_000_000)[0], 400)
        audio_path = f"/api/messages/{voice['id']}/audio"
        self.assertEqual(self.request("GET", audio_path, token=outsider)[0], 404)
        self.assertEqual(self.request("GET", audio_path)[0], 401)
        for token in (a, b):
            request = Request(self.base + audio_path, headers={"Authorization": "Bearer " + token})
            with urlopen(request, timeout=5) as response:
                self.assertEqual(response.headers["Content-Type"], "audio/mp4")
                self.assertEqual(response.read(), audio)
        history = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]
        self.assertEqual(history["items"][0]["id"], voice["id"])
        reply_body = {"clientMessageId": str(uuid4()), "text": "Trả lời bằng văn bản",
                      "replyToMessageId": voice["id"]}
        status, reply = self.request("POST", f"/api/conversations/{cid}/messages", reply_body, b)
        self.assertEqual(status, 201)
        self.assertEqual(reply["replyTo"]["kind"], "voice")
        self.assertEqual(reply["replyTo"]["senderId"], alice["user"]["id"])
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", reply_body, b)[0], 200)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", {
            **reply_body, "replyToMessageId": original["id"],
        }, b)[0], 409)
        _, other = self.request("POST", "/api/conversations", {
            "peerUserId": stranger["user"]["id"],
        }, a)
        self.assertEqual(self.request("POST", f"/api/conversations/{other['id']}/messages", {
            **reply_body, "clientMessageId": str(uuid4()),
        }, a)[0], 400)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", {
            **reply_body, "clientMessageId": str(uuid4()), "replyToMessageId": str(uuid4()),
        }, a)[0], 400)
        self.assertEqual(self.voice_request(path, a, str(uuid4()), audio,
                                           reply_id=str(uuid4()))[0], 400)
        self.stop_server()
        self.start_server()
        history = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]
        self.assertEqual(history["items"][0]["replyTo"]["id"], voice["id"])
        self.assertEqual(history["items"][1]["replyTo"]["text"], original["text"])
        request = Request(self.base + audio_path, headers={"Authorization": "Bearer " + a})
        with urlopen(request, timeout=5) as response:
            self.assertEqual(response.read(), audio)

        status, recalled = self.request("PUT", f"/api/messages/{voice['id']}/recall", token=a)
        self.assertEqual(status, 200)
        self.assertTrue(recalled["isRecalled"])
        self.assertIsNone(recalled["voiceDurationMs"])
        self.assertEqual(self.request("GET", audio_path, token=b)[0], 404)
        updated_reply = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]["items"][0]
        self.assertEqual(updated_reply["replyTo"]["text"], "Tin nhắn đã thu hồi")

    def test_recall_message_authorization_realtime_and_persistence(self):
        suffix = uuid4().hex[:8]
        _, alice = self.request("POST", "/api/auth/register", {
            "displayName": "Alice", "email": f"recall-a-{suffix}@example.com",
            "password": "alice-pass-123",
        })
        _, bob = self.request("POST", "/api/auth/register", {
            "displayName": "Bob", "email": f"recall-b-{suffix}@example.com",
            "password": "bob-pass-123",
        })
        _, outsider = self.request("POST", "/api/auth/register", {
            "displayName": "Outsider", "email": f"recall-c-{suffix}@example.com",
            "password": "outsider-pass-123",
        })
        a, b, c = (user["accessToken"] for user in (alice, bob, outsider))
        cid = self.request("POST", "/api/conversations", {
            "peerUserId": bob["user"]["id"],
        }, a)[1]["id"]
        _, first = self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "Secret message",
        }, a)
        _, reply = self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "I saw it",
            "replyToMessageId": first["id"],
        }, b)
        path = f"/api/messages/{first['id']}/recall"
        self.assertEqual(self.request("PUT", path)[0], 401)
        self.assertEqual(self.request("PUT", path, token=c)[0], 404)
        self.assertEqual(self.request("PUT", path, token=b)[0], 403)
        negotiation = self.request("POST", "/hubs/chat/negotiate?negotiateVersion=1", token=b)[1]
        realtime = SignalRSocket(self.port, negotiation["connectionToken"], b)
        try:
            time.sleep(0.1)
            status, recalled = self.request("PUT", path, token=a)
            self.assertEqual(status, 200)
            self.assertTrue(recalled["isRecalled"])
            self.assertEqual(recalled["text"], "")
            self.assertEqual(recalled["reactions"], {})
            event = realtime.next_record()
            self.assertEqual(event["target"], "MessageUpdated")
            self.assertEqual(event["arguments"][0]["id"], first["id"])
            self.assertTrue(event["arguments"][0]["isRecalled"])
            reply_event = realtime.next_record()
            self.assertEqual(reply_event["target"], "MessageUpdated")
            self.assertEqual(reply_event["arguments"][0]["id"], reply["id"])
            self.assertEqual(reply_event["arguments"][0]["replyTo"]["text"], "Tin nhắn đã thu hồi")
        finally:
            realtime.close()
        self.assertEqual(self.request("PUT", path, token=a)[1], recalled)
        page = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]
        self.assertEqual(page["items"][1]["text"], "")
        self.assertTrue(page["items"][1]["isRecalled"])
        self.assertEqual(page["items"][0]["replyTo"]["text"], "Tin nhắn đã thu hồi")
        self.assertEqual(self.request("PUT", f"/api/messages/{first['id']}/heart", token=b)[0], 400)
        self.assertEqual(self.request("POST", f"/api/conversations/{cid}/messages", {
            "clientMessageId": str(uuid4()), "text": "another reply",
            "replyToMessageId": first["id"],
        }, b)[0], 400)
        self.stop_server()
        self.start_server()
        persisted = self.request("GET", f"/api/conversations/{cid}/messages", token=b)[1]
        self.assertTrue(persisted["items"][1]["isRecalled"])
        self.assertEqual(persisted["items"][1]["text"], "")

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
        self.assertEqual(self.request("GET", f"/api/users/{bob['user']['id']}", token=a),
                         (200, bob["user"]))
        self.assertEqual(self.request("GET", f"/api/users/{bob['user']['id']}")[0], 401)
        self.assertEqual(self.request("GET", f"/api/users/{alice['user']['id']}", token=a)[0], 404)
        self.assertEqual(self.request("GET", f"/api/users/{uuid4()}", token=a)[0], 404)
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

        first_payload = {"clientMessageId": str(uuid4()), "text": "Xin chào! 🥰"}
        realtime = SignalRSocket(self.port, bob_negotiation["connectionToken"], b)
        try:
            time.sleep(0.1)  # Let OnConnectedAsync add Bob to his private user group.
            status, first = self.request("POST", f"/api/conversations/{cid}/messages", first_payload, a)
            event = realtime.next_record()
            self.assertEqual(event["target"], "MessageCreated")
            self.assertEqual(event["arguments"][0]["id"], first["id"])
            heart_path = f"/api/messages/{first['id']}/heart"
            self.assertEqual(self.request("PUT", heart_path, token=outsider)[0], 404)
            heart_status, hearted = self.request("PUT", heart_path, token=b)
            self.assertEqual(heart_status, 200)
            self.assertEqual(hearted["heartedBy"], [bob["user"]["id"]])
            heart_event = realtime.next_record()
            while heart_event.get("target") == "ConversationUpdated":
                heart_event = realtime.next_record()
            self.assertEqual(heart_event["target"], "MessageUpdated")
            self.assertEqual(heart_event["arguments"][0]["heartedBy"], hearted["heartedBy"])
            self.assertEqual(self.request("PUT", heart_path, token=b)[1]["heartedBy"], hearted["heartedBy"])
            self.assertEqual(len(self.request("PUT", heart_path, token=a)[1]["heartedBy"]), 2)
            self.assertEqual(self.request("DELETE", heart_path, token=b)[1]["heartedBy"], [alice["user"]["id"]])
            self.assertEqual(self.request("DELETE", heart_path, token=b)[1]["heartedBy"], [alice["user"]["id"]])
            reaction_path = f"/api/messages/{first['id']}/reaction"
            self.assertEqual(self.request("PUT", reaction_path, {"type": "like"}, outsider)[0], 404)
            self.assertEqual(self.request("PUT", reaction_path, {"type": "invalid"}, b)[0], 400)
            liked = self.request("PUT", reaction_path, {"type": "like"}, b)[1]
            self.assertEqual(liked["reactions"], {
                alice["user"]["id"]: "heart", bob["user"]["id"]: "like",
            })
            self.assertEqual(liked["heartedBy"], [alice["user"]["id"]])
            self.assertEqual(liked["reactionSets"][bob["user"]["id"]], ["like"])
            self.assertEqual(self.request("PUT", reaction_path, {"type": "like"}, b)[1]["reactions"], liked["reactions"])
            wow = self.request("PUT", reaction_path, {"type": "wow"}, b)[1]
            self.assertEqual(wow["reactionSets"][bob["user"]["id"]], ["like", "wow"])
            after_wow = self.request("DELETE", reaction_path + "/wow", token=b)[1]
            self.assertEqual(after_wow["reactionSets"][bob["user"]["id"]], ["like"])
            self.assertNotIn(bob["user"]["id"], self.request("DELETE", reaction_path, token=b)[1]["reactions"])
            self.assertEqual(self.request("PUT", reaction_path, {"type": "angry"}, b)[1]["reactions"][bob["user"]["id"]], "angry")
            own_laugh = self.request("PUT", reaction_path, {"type": "laugh"}, a)[1]
            self.assertEqual(own_laugh["reactionSets"][alice["user"]["id"]], ["heart", "laugh"])
            own_without_heart = self.request("DELETE", reaction_path + "/heart", token=a)[1]
            self.assertEqual(own_without_heart["reactionSets"][alice["user"]["id"]], ["laugh"])
            self.request("PUT", reaction_path, {"type": "heart"}, a)
            delivered_path = f"/api/conversations/{cid}/delivered"
            self.assertEqual(self.request("POST", delivered_path, {
                "throughSequence": 1,
            }, outsider)[0], 404)
            self.assertEqual(self.request("POST", delivered_path, {
                "throughSequence": -1,
            }, b)[0], 400)
            self.assertEqual(self.request("POST", delivered_path, {
                "throughSequence": 1,
            }, b)[1]["lastDeliveredSequence"], 1)
            delivered_event = realtime.next_record()
            while delivered_event.get("target") != "MessageDelivered":
                delivered_event = realtime.next_record()
            self.assertEqual(delivered_event["arguments"][0], {
                "conversationId": cid,
                "userId": bob["user"]["id"],
                "lastDeliveredSequence": 1,
            })
            self.assertEqual(self.request("POST", delivered_path, {
                "throughSequence": 0,
            }, b)[1]["lastDeliveredSequence"], 1)
            alice_conversation = self.request("GET", "/api/conversations", token=a)[1][0]
            self.assertEqual(alice_conversation["peerLastDeliveredSequence"], 1)
            self.assertEqual(alice_conversation["peerLastReadSequence"], 0)
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
        self.assertEqual(older["items"][0]["heartedBy"], [alice["user"]["id"]])
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
        self.assertEqual(self.request("GET", "/api/conversations", token=b)[1][0]["peerLastDeliveredSequence"], 2)

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
        self.assertEqual(history["items"][1]["text"], "Xin chào! 🥰")
        self.assertEqual(history["items"][1]["heartedBy"], [alice["user"]["id"]])
        self.assertEqual(history["items"][1]["reactions"][bob["user"]["id"]], "angry")


if __name__ == "__main__":
    unittest.main()
