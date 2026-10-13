# Chat API (local MVP)

ASP.NET Core 10 API for one-to-one text chat. This is a runnable MVP for two or more locally registered accounts. It does not create sample accounts or messages.

## Run

```sh
cd backend/src/Chat.Api
ASPNETCORE_ENVIRONMENT=Development dotnet run --urls http://127.0.0.1:5080
```

The default data file is `backend/src/Chat.Api/data/chat-state.json`. Set `Chat__DataPath` to use another path. In Development, the server generates a signing key in the same data directory. In any other environment, set a secret of at least 32 bytes with `Chat__SigningKey`; the server refuses to start without it. HTTPS is required when deployed beyond localhost. The file store is intended for a single server process; use a transactional database and shared SignalR backplane before scaling horizontally.

No third-party NuGet packages are required. Run `python3 backend/tests/smoke.py` from the repository root after building to exercise auth, message ordering, retries, read receipts, access control, refresh rotation, live SignalR delivery, and persistence across restart.

For physical device testing, bind the server to a reachable interface (for example `--urls http://0.0.0.0:5080`) and point the mobile client at the host's LAN address. Use a trusted development network; deploy with HTTPS before using non-test credentials.

The OpenAPI 3.1 contract is available at `/openapi/v1.json` while the server runs and in [`src/Chat.Api/openapi.json`](src/Chat.Api/openapi.json). Auth endpoints are limited to 20 requests per minute per IP; message sends are limited to 60 per minute per account.

## REST contract

All IDs are UUID strings. Times are UTC ISO 8601 strings. Protected endpoints require `Authorization: Bearer <accessToken>`. JSON properties use camelCase. Validation failures have `{"code":"validation_error","message":"..."}`; access failures use HTTP 401 or 403. `clientMessageId` should be a UUID generated and persisted by the client before its first send attempt.

| Method | Route | Request | Response |
| --- | --- | --- | --- |
| POST | `/api/auth/register` | `{displayName,email,password}` | 201 `{user,accessToken,refreshToken}` |
| POST | `/api/auth/login` | `{email,password}` | 200 `{user,accessToken,refreshToken}` |
| POST | `/api/auth/refresh` | `{refreshToken}` | 200 `{user,accessToken,refreshToken}`; old refresh token is revoked |
| GET | `/api/auth/me` | none | `User` |
| GET | `/api/users?query=...` | none | `User[]` excluding caller, max 50 |
| GET | `/api/conversations` | none | `Conversation[]` newest activity first |
| POST | `/api/conversations` | `{peerUserId}` | `Conversation`; repeated creation returns the existing conversation |
| GET | `/api/conversations/{id}/messages?beforeSequence=123&limit=30` | none | `{items:Message[],nextCursor:number?}`; newest first, next cursor is the oldest returned sequence |
| POST | `/api/conversations/{id}/messages` | `{clientMessageId,text}` | 201 `Message` or 200 for an identical retry; same ID with different text is 409 |
| POST | `/api/conversations/{id}/read` | `{throughSequence}` | `{lastReadSequence}`; cursor advances monotonically |

`User`: `{id,displayName,email}`. `Message`: `{id,clientMessageId,conversationId,senderId,text,sequence,createdAt}`. `Conversation`: `{id,peer:User,lastMessage:Message?,unreadCount,lastReadSequence,peerLastReadSequence}`. Both read sequence fields are scoped to the current conversation: `lastReadSequence` belongs to the authenticated user; `peerLastReadSequence` belongs to the peer. `nextCursor` is null at the end of history. A message with `sequence < beforeSequence` is returned on the next page, so clients avoid duplicate boundary items.

For example, register two accounts, create a conversation with the other user's ID, then send:

```json
{"clientMessageId":"a67b4864-43b4-43a7-84b4-3b6dbd117510","text":"Xin chào!"}
```

## Realtime contract

Connect to `/hubs/chat` using the access token in the `Authorization` header. SignalR's WebSocket `access_token` query parameter is accepted only for this hub path. All connections for a user join a private user group automatically; there is no client-supplied group ID. The server pushes to both conversation members after a successful write:

- `MessageCreated(Message)` when a new message is committed. An idempotent retry does not re-emit it.
- `ConversationUpdated(Conversation)` with each recipient's own unread/read fields.
- `MessageRead({conversationId,userId,lastReadSequence})` after a read cursor advances.

On reconnect, fetch `/api/conversations/{id}/messages` with cursor pagination and reconcile by message ID or `clientMessageId`. Concurrent writes can make events arrive out of order; sort messages by `sequence`. SignalR is an update channel; REST is the source of truth.

## Scope and operational notes

The file store writes an atomic snapshot after each mutation, holds an exclusive process lock, and keeps password hashes and refresh token hashes only. The application is single-process and optimized for a local two-device MVP. It does not yet implement group chat, attachments, push notifications, presence, delivery receipts, E2EE, database migrations, distributed realtime, or backup automation. Back up the data file while the server is stopped. Set `Chat__DataPath` to an OS-protected location and restrict file permissions in deployment.
