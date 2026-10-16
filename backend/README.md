# Chat API (local MVP)

ASP.NET Core 8 API for one-to-one text, voice, image and file chat. This is a runnable MVP for two or more locally registered accounts. It does not create sample accounts or messages.

## Chạy bằng Visual Studio trên Windows

1. Mở `backend/ZaloChat.sln` bằng Visual Studio 2022 có workload **ASP.NET and web development** và .NET 8 SDK.
2. Nếu cần, nhấn chuột phải vào **Chat.Api** → **Set as Startup Project**.
3. Chọn profile **Chat.Api**, nhấn **F5** (debug) hoặc **Ctrl+F5** (chạy).
4. Trình duyệt mở `http://localhost:5080/health` và trả về `{"status":"ok"}`. Hợp đồng API tại `http://localhost:5080/openapi/v1.json`.

Profile đã thiết lập môi trường Development; khóa ký và dữ liệu sẽ được tạo tự động trong thư mục `src/Chat.Api/data`. Không cần cài SQL Server cho bản backend hiện tại.

Chạy và build bằng PowerShell từ thư mục gốc dự án:

```powershell
dotnet build .\backend\ZaloChat.sln
dotnet run --project .\backend\src\Chat.Api --launch-profile Chat.Api
```

Profile `Chat.Api` lắng nghe trên mọi giao diện mạng tại cổng 5080. Flutter Android Emulator dùng `http://10.0.2.2:5080`; điện thoại thật dùng `http://<IP-LAN-của-máy-chạy-API>:5080`; Flutter Windows dùng `http://localhost:5080`. Chỉ cần sửa `AppConfig.apiBaseUrl` trong `lib/core/config/app_config.dart`. Dừng backend đang chạy trước khi mở một phiên khác vì mỗi tệp dữ liệu chỉ cho phép một tiến trình truy cập.

## Run

```sh
cd backend/src/Chat.Api
dotnet run --launch-profile Chat.Api
```

The default data file is `backend/src/Chat.Api/data/chat-state.json`. Set `Chat__DataPath` to use another path. In Development, the server generates a signing key in the same data directory. In any other environment, set a secret of at least 32 bytes with `Chat__SigningKey`; the server refuses to start without it. HTTPS is required when deployed beyond localhost. The file store is intended for a single server process; use a transactional database and shared SignalR backplane before scaling horizontally.

No third-party NuGet packages are required. Run `python3 backend/tests/smoke.py` from the repository root after building to exercise auth, message ordering, retries, read receipts, access control, refresh rotation, live SignalR delivery, and persistence across restart.

The `Chat.Api` launch profile binds to `http://0.0.0.0:5080` for physical device testing. Point the mobile client at the host's LAN address and allow port 5080 through the host firewall. Use a trusted development network; deploy with HTTPS before using non-test credentials.

The OpenAPI 3.1 contract is available at `/openapi/v1.json` while the server runs and in [`src/Chat.Api/openapi.json`](src/Chat.Api/openapi.json). Auth endpoints are limited to 20 requests per minute per IP; message sends are limited to 60 per minute per account.

## REST contract

All IDs are UUID strings. Times are UTC ISO 8601 strings. Protected endpoints require `Authorization: Bearer <accessToken>`. JSON properties use camelCase. Validation failures have `{"code":"validation_error","message":"..."}`; access failures use HTTP 401 or 403. `clientMessageId` should be a UUID generated and persisted by the client before its first send attempt.

| Method | Route | Request | Response |
| --- | --- | --- | --- |
| POST | `/api/auth/register` | `{displayName,email,password}` | 201 `{user,accessToken,refreshToken}` |
| POST | `/api/auth/login` | `{email,password}` | 200 `{user,accessToken,refreshToken}` |
| POST | `/api/auth/refresh` | `{refreshToken}` | 200 `{user,accessToken,refreshToken}`; old refresh token is revoked |
| GET | `/api/auth/me` | none | `User` |
| PUT | `/api/auth/me` | `{displayName,email}` | Updated `User`; duplicate email returns 409 |
| PUT | `/api/auth/me/profile` | multipart `displayName`, `email`, optional `avatar` (max 5 MB) or `removeAvatar=true` | Updated `User`, saved atomically; publishes updated peer details to existing conversations |
| GET | `/api/users/{id}/avatar/{version}` | signed-in user | Current avatar image; previous versions return 404 after replacement/removal |
| GET | `/api/users?query=...` | none | `User[]` excluding caller, max 50 |
| GET | `/api/conversations` | none | `Conversation[]` newest activity first |
| POST | `/api/conversations` | `{peerUserId}` | `Conversation`; repeated creation returns the existing conversation |
| GET | `/api/conversations/{id}/messages?beforeSequence=123&limit=30` | none | `{items:Message[],nextCursor:number?}`; newest first, next cursor is the oldest returned sequence |
| POST | `/api/conversations/{id}/messages` | `{clientMessageId,text,replyToMessageId?}` | 201 `Message` or 200 for an identical retry; same ID with different text is 409 |
| POST | `/api/conversations/{id}/attachments` | multipart `clientMessageId`, `kind` (`image` or `file`), `file`, optional `text` and `replyToMessageId` | 201 `Message` or 200 for an identical retry; 1 byte to 20 MB |
| GET | `/api/messages/{id}/attachment` | conversation member | attachment bytes; unavailable after recall |
| POST | `/api/conversations/{id}/voice` | multipart `clientMessageId`, `durationMs`, `audio` (`.m4a`), optional `replyToMessageId` | 201 `Message` or 200 for an identical retry; up to 2 MB and 120 seconds |
| GET | `/api/messages/{id}/audio` | none | `audio/mp4`; only conversation members may download |
| PUT | `/api/messages/{id}/heart` | none | 200 `Message`; adds the caller's heart, idempotent |
| DELETE | `/api/messages/{id}/heart` | none | 200 `Message`; removes the caller's heart, idempotent |
| PUT | `/api/messages/{id}/reaction` | `{type}`: `heart`, `like`, `laugh`, `wow`, `sad`, or `angry` | 200 `Message`; sets or replaces the caller's reaction |
| DELETE | `/api/messages/{id}/reaction` | none | 200 `Message`; removes the caller's reaction |
| POST | `/api/conversations/{id}/read` | `{throughSequence}` | `{lastReadSequence}`; cursor advances monotonically |
| POST | `/api/conversations/{id}/delivered` | `{throughSequence}` | `{lastDeliveredSequence}`; cursor advances monotonically |

`User`: `{id,displayName,email,avatarUrl}`. `avatarUrl` is null or a versioned relative path requiring bearer authentication. `Message`: `{id,clientMessageId,conversationId,senderId,text,kind,voiceDurationMs,sequence,createdAt,heartedBy,reactions,replyTo}`; `kind` is `text`, `voice`, `image` or `file`; `voiceDurationMs` is null except for voice messages. Image/file messages include `attachment: {name,size,contentType}` and an optional caption in `text`. Images are recognized by their signature; other files download as `application/octet-stream`. `reactions` maps user IDs to reaction types, with one reaction per user per message. `heartedBy` remains for compatibility and contains only users whose current reaction is `heart`. `Conversation`: `{id,peer:User,lastMessage:Message?,unreadCount,lastReadSequence,peerLastReadSequence,lastDeliveredSequence,peerLastDeliveredSequence}`. The `last*` cursors belong to the authenticated user; `peerLast*` cursors belong to the peer. Delivery means the recipient app has stored the message; read means the recipient opened the conversation. A read cursor also advances delivery. `nextCursor` is null at the end of history. A message with `sequence < beforeSequence` is returned on the next page, so clients avoid duplicate boundary items.

For example, register two accounts, create a conversation with the other user's ID, then send:

```json
{"clientMessageId":"a67b4864-43b4-43a7-84b4-3b6dbd117510","text":"Xin chào!"}
```

`replyTo` is null or `{id,senderId,text,kind}`. The server creates this quote from a message in the same conversation; clients send only `replyToMessageId`. Text, voice, image and file messages can quote any non-recalled message in the conversation. Reusing a client ID with a different reply target returns 409.

## Realtime contract

Connect to `/hubs/chat` using the access token in the `Authorization` header. SignalR's WebSocket `access_token` query parameter is accepted only for this hub path. All connections for a user join a private user group automatically; there is no client-supplied group ID. The server pushes to both conversation members after a successful write:

- `MessageCreated(Message)` when a new message is committed. An idempotent retry does not re-emit it.
- `MessageUpdated(Message)` when a heart is added or removed.
- `ConversationUpdated(Conversation)` with each recipient's own unread/read fields.
- `MessageRead({conversationId,userId,lastReadSequence})` after a read cursor advances.
- `MessageDelivered({conversationId,userId,lastDeliveredSequence})` after a delivery cursor advances.

On reconnect, fetch `/api/conversations/{id}/messages` with cursor pagination and reconcile by message ID or `clientMessageId`. Concurrent writes can make events arrive out of order; sort messages by `sequence`. SignalR is an update channel; REST is the source of truth.

## Scope and operational notes

Voice files and attachments are stored in private `voice/`, `attachments/` and `avatars/` directories next to `Chat__DataPath`. Back up those directories and the JSON data file together while the server is stopped. The file store writes an atomic snapshot after each mutation, holds an exclusive process lock, and keeps password hashes and refresh token hashes only. The application is single-process and optimized for a local two-device MVP. It does not yet implement group chat, video previews, push notifications, presence, delivery receipts, E2EE, database migrations, distributed realtime, or backup automation. Back up the data file while the server is stopped. Set `Chat__DataPath` to an OS-protected location and restrict file permissions in deployment.

The Flutter composer opens an image/file picker from the paperclip button when empty. Select one file (up to 20 MB), add an optional caption, then send. Images have an inline preview and a zoom viewer; documents download into the per-account private cache and open in an installed app. Failed uploads stay in the composer for an identical retry during the current session; only text messages use the durable offline outbox. Restart Flutter after adding the native file-picker/open-file plugins, and restart the API for the new endpoints.

The profile screen supports changing the name/email and selecting or removing an avatar before saving. Flutter accepts source images up to 10 MB and prepares a centered 512×512 PNG; the server independently checks the image signature and 5 MB upload limit. New avatar URLs propagate through user and conversation DTOs; the authenticated avatar loader uses the existing token refresh flow.
