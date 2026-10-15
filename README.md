# YÊU CẦU XÂY DỰNG ỨNG DỤNG CHAT CHUYÊN NGHIỆP

## Trạng thái triển khai hiện tại

Kho mã đã có một luồng chat văn bản và tin nhắn thoại 1–1 chạy với dữ liệu thật: đăng ký/đăng nhập, tìm người dùng, tạo hội thoại, gửi và nhận tin qua API + SignalR, chọn emoji, nhấn giữ để thả tim/thích/cười/ngạc nhiên/khóc/tức giận, sao chép hoặc trả lời tin nhắn, phân trang lịch sử, trạng thái đã đọc, lưu cache và hàng đợi gửi khi mất mạng. Flutter dùng Riverpod, GoRouter, Dio, Drift và giao diện Material 3 sáng/tối. Backend ASP.NET Core và hợp đồng OpenAPI nằm trong [`backend/`](backend/README.md). Các mục bên dưới là **đặc tả phát triển tiếp**, không phải danh sách tính năng đã hoàn tất. Chat nhóm, hình ảnh/video/tài liệu, gọi, thông báo đẩy, presence và E2EE chưa được triển khai. Tin nhắn thoại ghi tối đa 2 phút, gửi tệp `.m4a` tối đa 2 MB và phát lại trong hội thoại; cần cấp quyền micro cho ứng dụng.

Tin nhắn của bạn hiển thị **Đã gửi** khi API lưu thành công, **Đã nhận** khi ứng dụng của người nhận đã tải và lưu tin, và **Đã xem** khi người nhận mở cuộc trò chuyện. Trạng thái cập nhật qua SignalR và được đồng bộ lại khi kết nối trở lại.

### Chạy thử

Trong màn hình chat, chạm biểu tượng micro cạnh ô nhập để mở bảng ghi âm. Chọn **Gửi bản ghi âm** hoặc **Gửi dạng văn bản**, rồi chạm nút micro lớn để bắt đầu và chạm lần nữa để dừng. Với dạng văn bản, ứng dụng ưu tiên tiếng Việt nếu thiết bị có hỗ trợ; nếu không sẽ dùng ngôn ngữ nhận dạng mặc định và hiển thị tên ngôn ngữ đang nghe. Nội dung nhận dạng có thể sửa trong ô soạn trước khi gửi; **Hủy nhập giọng nói** khôi phục bản nháp trước khi nói. Với bản ghi âm, bạn có thể xóa hoặc gửi sau khi dừng.

Nhận dạng dùng dịch vụ của Android/iOS qua [`speech_to_text`](https://pub.dev/packages/speech_to_text), dành cho câu chat ngắn và có thể cần mạng. Cần cấp quyền micro và, trên iOS, quyền nhận dạng giọng nói. Máy ảo phải có dịch vụ nhận dạng và micro hoạt động; khi dịch vụ không khả dụng, ứng dụng giữ bản nháp và cho phép thử lại. Sau khi thêm plugin, chạy lại ứng dụng hoàn toàn để nạp mã native.

1. Khởi động backend trên máy phát triển (lệnh này nhận kết nối trên cổng 5080 từ máy local và thiết bị cùng mạng LAN):

   ```sh
   cd backend/src/Chat.Api
   dotnet run --launch-profile Chat.Api
   ```

   Kiểm tra API tại `http://localhost:5080/health`. Nếu chạy trên điện thoại thật, hai thiết bị cần cùng mạng và tường lửa máy chạy backend cần cho phép cổng 5080.

2. Mở [`lib/core/config/app_config.dart`](lib/core/config/app_config.dart), sửa duy nhất `AppConfig.apiBaseUrl` thành địa chỉ máy chạy API (không thêm dấu `/` ở cuối). Sau đó, ở terminal khác chạy Flutter. Tạo hai tài khoản trong ứng dụng để thử nhắn tin; backend không tạo dữ liệu mẫu.

   ```sh
   flutter pub get
   flutter run
   ```

   Dùng `http://10.0.2.2:5080` cho Android Emulator, `http://127.0.0.1:5080` cho iOS Simulator, hoặc `http://<IP-LAN-của-máy-chạy-API>:5080` cho điện thoại thật khi hai máy kết nối được với nhau qua LAN. URL hiện tại trong file là `http://127.0.0.1:5080` để dùng với Android cắm USB và `adb reverse` như hướng dẫn bên dưới. Khi chuyển máy, chỉ cần đổi URL này; đường dẫn Android SDK và Flutter SDK được Flutter tạo riêng trên từng máy trong `android/local.properties`. Android debug cho phép HTTP để thử nghiệm nội bộ; bản phát hành cần endpoint HTTPS. iOS khai báo quyền kết nối mạng nội bộ. Không sử dụng tài khoản thật trên máy chủ HTTP thử nghiệm.

   Nếu cần APK để cài và thử trên máy Android, dùng `flutter build apk --debug`. File đầu ra nằm ở `build/app/outputs/flutter-apk/app-debug.apk`.

   Khi cập nhật mã backend hoặc thêm plugin Flutter, hãy khởi động lại backend và chạy lại ứng dụng. Hàng đợi gửi khi mất mạng hiện chỉ áp dụng cho tin văn bản; bản ghi âm gửi lỗi có thể thử lại khi còn ở màn hình chat.

   Nếu dùng **Android thật cắm USB**, có thể giữ backend ở `127.0.0.1:5080` và chuyển tiếp cổng qua ADB:

   ```sh
   adb reverse tcp:5080 tcp:5080
   flutter run
   ```

   Trước khi chạy, đổi `AppConfig.apiBaseUrl` thành `http://127.0.0.1:5080`. Chạy lại `adb reverse` sau khi rút/cắm lại thiết bị. Log `[API]` trong Flutter debug hiển thị địa chỉ gọi, mã HTTP hoặc loại lỗi kết nối; log không chứa header, token hay nội dung request.

3. Kiểm tra mã nguồn:

   ```sh
   flutter analyze
   flutter test
   dotnet build backend/src/Chat.Api/Chat.Api.csproj
   python3 backend/tests/smoke.py
   ```

Backend hiện lưu dữ liệu bền vững trong một tiến trình bằng tệp cục bộ. Trước khi triển khai quy mô lớn, cần thay bằng cơ sở dữ liệu giao dịch, bổ sung thông báo đẩy, vận hành HTTPS, sao lưu và các tính năng còn lại trong đặc tả.

**Tên dự án:** Flutter Chat App  
**Nền tảng:** Android, iOS  
**Frontend:** Flutter + Dart + Riverpod  
**Kiến trúc:** Feature-first Clean Architecture  
**Mục tiêu:** Xây dựng ứng dụng nhắn tin thời gian thực với trải nghiệm tương tự Zalo, Telegram và Messenger.

## 1. Yêu cầu tổng thể

Xây dựng ứng dụng Chat chuyên nghiệp, hiện đại, có khả năng mở rộng, hiệu năng cao và bảo mật tốt.

Ứng dụng phải đáp ứng:

- Giao diện đẹp, hiện đại, chuyên nghiệp, tương tự Zalo nhưng có bản sắc riêng.
- Hoạt động mượt mà trên Android và iOS.
- Nhắn tin thời gian thực với độ trễ thấp.
- Hỗ trợ chat cá nhân và chat nhóm.
- Hỗ trợ gửi hình ảnh, video, âm thanh, tài liệu.
- Đồng bộ tin nhắn giữa nhiều thiết bị.
- Nhận thông báo khi có tin nhắn mới.
- Hỗ trợ chế độ sáng và tối.
- Hoạt động khi mất kết nối Internet với dữ liệu đã lưu cục bộ.
- Kiến trúc rõ ràng, dễ bảo trì, dễ kiểm thử và mở rộng.

## 2. Công nghệ và kiến trúc

### 2.1. Frontend

- Flutter và Dart phiên bản stable tương thích.
- Riverpod quản lý trạng thái ứng dụng.
- GoRouter quản lý điều hướng.
- Dio thực hiện HTTP API.
- WebSocket hoặc SignalR để giao tiếp thời gian thực.
- Freezed và json_serializable để tạo model bất biến và hỗ trợ JSON.
- Drift hoặc Isar để lưu dữ liệu cục bộ, lựa chọn một giải pháp chính.
- flutter_secure_storage để lưu thông tin xác thực nhạy cảm.
- Firebase Cloud Messaging để nhận push notification.
- Material 3 kết hợp hệ thống thiết kế riêng.

### 2.2. Backend đề xuất

- ASP.NET Core Web API.
- SignalR Hub để truyền nhận sự kiện thời gian thực.
- SQL Server hoặc PostgreSQL để lưu dữ liệu nghiệp vụ.
- Redis hỗ trợ cache, presence và scale-out.
- Object Storage để lưu hình ảnh, video và tệp đính kèm.
- JWT Access Token và Refresh Token để xác thực.

Backend cần được thiết kế độc lập với Flutter để có thể mở rộng sang Web và Desktop.

### 2.3. Clean Architecture

Tổ chức theo từng tính năng:

```text
lib/
├── app/
│   ├── app.dart
│   ├── router/
│   └── bootstrap/
├── core/
│   ├── config/
│   ├── constants/
│   ├── database/
│   ├── errors/
│   ├── network/
│   ├── realtime/
│   ├── security/
│   ├── theme/
│   ├── utils/
│   └── widgets/
├── features/
│   ├── auth/
│   ├── conversations/
│   ├── chat/
│   ├── contacts/
│   ├── groups/
│   ├── calls/
│   ├── notifications/
│   ├── search/
│   ├── media/
│   ├── profile/
│   └── settings/
└── main.dart
```

Mỗi feature được chia thành:

```text
feature/
├── data/
│   ├── datasources/
│   ├── models/
│   └── repositories/
├── domain/
│   ├── entities/
│   ├── repositories/
│   └── usecases/
└── presentation/
    ├── pages/
    ├── widgets/
    └── providers/
```

Không được đặt logic nghiệp vụ trực tiếp trong Widget.

## 3. Thiết kế giao diện

### 3.1. Nguyên tắc UI/UX

- Phong cách hiện đại, tối giản nhưng cao cấp.
- Giao diện lấy cảm hứng từ Zalo.
- Ưu tiên trải nghiệm người dùng Việt Nam.
- Màu chủ đạo xanh dương, nền trắng và màu trung tính.
- Bo góc hợp lý, khoảng cách nhất quán.
- Animation nhẹ, tự nhiên.
- Có Skeleton Loading và trạng thái Empty/Error.
- Responsive theo kích thước màn hình.
- Hỗ trợ Dark Mode.
- Hỗ trợ Accessibility và thay đổi kích thước chữ.

### 3.2. Thanh điều hướng chính

Gồm 4 mục:

1. Tin nhắn
2. Danh bạ
3. Nhật ký
4. Cá nhân

Mục Nhật ký được thiết kế thành module tùy chọn, có thể bổ sung sau.

## 4. Màn hình danh sách cuộc trò chuyện

Hiển thị:

- Avatar cá nhân hoặc nhóm.
- Tên người dùng hoặc tên nhóm.
- Nội dung tin nhắn cuối cùng.
- Thời gian tin nhắn gần nhất.
- Số lượng tin nhắn chưa đọc.
- Trạng thái Online.
- Biểu tượng cuộc trò chuyện đã ghim.
- Biểu tượng tắt thông báo.
- Trạng thái đang nhập tin nhắn.

Chức năng:

- Tìm kiếm cuộc trò chuyện.
- Lọc tất cả/chưa đọc/nhóm.
- Ghim hoặc bỏ ghim.
- Đánh dấu đã đọc/chưa đọc.
- Tắt/bật thông báo.
- Lưu trữ cuộc trò chuyện.
- Xóa cuộc trò chuyện theo chính sách dữ liệu.
- Vuốt để thao tác nhanh.
- Pull to refresh.
- Phân trang danh sách.

Danh sách phải cập nhật theo sự kiện realtime, không tải lại toàn bộ khi có tin nhắn mới.

## 5. Màn hình Chat

### 5.1. Header

Hiển thị:

- Avatar người nhận.
- Tên người nhận.
- Trạng thái Online/Offline.
- Thời gian hoạt động gần nhất nếu được phép.
- Nút gọi thoại.
- Nút gọi video.
- Nút xem thông tin cuộc trò chuyện.

### 5.2. Danh sách tin nhắn

Hỗ trợ các loại tin nhắn:

- Văn bản.
- Emoji.
- Hình ảnh.
- Video.
- Voice Message.
- Tệp PDF, Word, Excel và các tệp cho phép.
- Vị trí.
- Danh thiếp.
- Tin nhắn trả lời.
- Tin nhắn chuyển tiếp.
- Tin nhắn hệ thống.

Tin nhắn phải có:

- Phân biệt người gửi và người nhận.
- Avatar và tên người gửi trong nhóm.
- Thời gian gửi.
- Trạng thái đang gửi.
- Đã gửi lên máy chủ.
- Đã chuyển tới thiết bị người nhận.
- Đã xem.
- Gửi thất bại và thử gửi lại.
- Nhóm tin nhắn theo thời gian.
- Hiển thị ngày giữa các nhóm tin nhắn.

### 5.3. Thao tác với tin nhắn

- Nhấn giữ để mở menu thao tác.
- Sao chép.
- Trả lời.
- Chuyển tiếp.
- Thả cảm xúc.
- Chỉnh sửa tin nhắn trong khoảng thời gian cho phép.
- Thu hồi tin nhắn.
- Xóa phía người dùng.
- Lưu tin nhắn quan trọng.
- Xem chi tiết trạng thái gửi/đọc.

### 5.4. Thanh nhập tin nhắn

- Ô nhập nhiều dòng.
- Emoji Picker.
- Nút đính kèm.
- Nút camera.
- Nút ghi âm.
- Nút gửi tin nhắn.
- Hiển thị Preview khi trả lời.
- Hiển thị Preview tệp trước khi gửi.
- Tự điều chỉnh theo bàn phím.
- Không che nội dung khi bàn phím xuất hiện.

### 5.5. Hiệu năng

- Virtualized/Lazy message list.
- Phân trang tin nhắn cũ.
- Giữ vị trí cuộn khi tải thêm.
- Tự cuộn hợp lý khi nhận tin nhắn mới.
- Không tự cuộn nếu người dùng đang đọc tin cũ.
- Hiển thị nút trở về tin nhắn mới nhất.
- Tối ưu rebuild bằng Riverpod select và chia nhỏ Widget.
- Cache ảnh và thumbnail.
- Không giải mã tệp lớn trên UI isolate.

## 6. Chat nhóm

Chức năng:

- Tạo nhóm.
- Đặt tên nhóm.
- Đổi avatar nhóm.
- Thêm/xóa thành viên.
- Mời thành viên qua liên kết.
- Phân quyền trưởng nhóm và quản trị viên.
- Ghim thông báo nhóm.
- Ghim tin nhắn.
- Tắt thông báo nhóm.
- Tìm kiếm thành viên.
- Rời nhóm.
- Giải tán nhóm theo quyền.
- Xem danh sách thành viên đã đọc tin nhắn.
- Kiểm soát quyền gửi tin nhắn và quản lý nhóm.

Mọi thao tác quản trị phải được backend kiểm tra quyền.

## 7. Danh bạ

- Danh sách bạn bè.
- Tìm kiếm theo tên, số điện thoại hoặc mã người dùng theo quyền riêng tư.
- Gửi lời mời kết bạn.
- Chấp nhận/từ chối lời mời.
- Hủy kết bạn.
- Chặn người dùng.
- Danh sách bạn bè Online.
- Đồng bộ danh bạ điện thoại khi được cấp quyền.
- Không tự động tải toàn bộ danh bạ lên máy chủ khi chưa có sự đồng ý.

## 8. Gọi thoại và video

Triển khai ở giai đoạn nâng cao:

- Gọi thoại 1-1.
- Gọi video 1-1.
- Hiển thị cuộc gọi đến.
- Từ chối/chấp nhận cuộc gọi.
- Bật/tắt microphone.
- Bật/tắt camera.
- Chuyển camera.
- Bật loa ngoài.
- Hiển thị thời lượng cuộc gọi.
- Lịch sử cuộc gọi.
- Xử lý cuộc gọi nhỡ.

Đề xuất WebRTC, kết hợp signaling server và TURN/STUN. Cần xử lý riêng vòng đời cuộc gọi trên Android và iOS.

## 9. Realtime và đồng bộ

Sử dụng SignalR hoặc WebSocket với các sự kiện:

```text
MessageCreated
MessageUpdated
MessageRecalled
MessageDeleted
MessageDelivered
MessageRead
TypingStarted
TypingStopped
UserPresenceChanged
ConversationUpdated
ReactionUpdated
GroupMemberChanged
```

Yêu cầu:

- Tự động kết nối lại khi mất mạng.
- Đồng bộ dữ liệu bị bỏ lỡ sau reconnect.
- Không tạo tin nhắn trùng lặp.
- Có clientMessageId để xử lý gửi lại an toàn.
- Mỗi conversation có sequence hoặc cursor.
- Lưu tin nhắn vào local database.
- Hàng đợi gửi tin nhắn khi offline.
- Đồng bộ lại khi có Internet.
- Xử lý thứ tự tin nhắn và sự kiện đến muộn.
- Không phụ thuộc hoàn toàn vào kết nối realtime.

REST API dùng cho tải lịch sử và đồng bộ; SignalR dùng cho cập nhật tức thời.

## 10. Quản lý trạng thái với Riverpod

Quy định:

- Sử dụng Provider để cung cấp repository và service.
- Sử dụng AsyncNotifier/Notifier cho trạng thái nghiệp vụ.
- Không gọi HTTP trực tiếp trong Widget.
- Không khởi tạo kết nối SignalR tại từng màn hình.
- Không lạm dụng StateProvider cho nghiệp vụ phức tạp.
- Không lưu BuildContext trong Provider.
- Tách trạng thái kết nối, cuộc trò chuyện và tin nhắn.
- Dùng immutable state.
- Hủy subscription đúng vòng đời.
- Tối ưu số lần rebuild.
- Viết unit test cho Notifier và Repository.

Các provider chính:

```text
authProvider
currentUserProvider
connectionStatusProvider
conversationListProvider
conversationDetailProvider
messagesProvider
messageComposerProvider
typingUsersProvider
unreadCountProvider
contactsProvider
groupMembersProvider
notificationSettingsProvider
```

## 11. Thông báo

Sử dụng Firebase Cloud Messaging cho Android và iOS.

- Thông báo tin nhắn mới.
- Hiển thị tên người gửi.
- Hiển thị nội dung theo cài đặt riêng tư.
- Nhấn thông báo mở đúng cuộc trò chuyện.
- Thông báo khi ứng dụng chạy nền hoặc đã đóng.
- Không hiển thị thông báo trùng khi ứng dụng đang mở cuộc trò chuyện.
- Hỗ trợ tắt thông báo theo từng cuộc trò chuyện.
- Đồng bộ trạng thái đọc để xử lý badge.
- Quản lý FCM token theo từng thiết bị.

## 12. Bảo mật

- HTTPS/TLS cho toàn bộ giao tiếp.
- Xác thực bằng Access Token và Refresh Token.
- Lưu token bằng secure storage.
- Refresh Token Rotation.
- Quản lý phiên đăng nhập theo thiết bị.
- Phân quyền và xác thực mọi API.
- Kiểm tra quyền truy cập cuộc trò chuyện ở backend.
- Kiểm tra loại tệp, dung lượng và quyền tải tệp.
- Không ghi token hoặc nội dung nhạy cảm vào log.
- Rate limiting chống spam.
- Chống gửi tin nhắn trùng.
- Bảo vệ dữ liệu cục bộ phù hợp với mức độ nhạy cảm.
- Có chính sách lưu trữ, xóa và sao lưu dữ liệu.

Mã hóa đầu cuối (E2EE) là một hạng mục bảo mật riêng, không được tuyên bố đã hỗ trợ nếu chưa thiết kế và kiểm thử giao thức quản lý khóa đầy đủ.

## 13. Thiết kế cơ sở dữ liệu

Các bảng chính:

```text
Users
UserDevices
UserSessions
Contacts
FriendRequests
Conversations
ConversationMembers
Messages
MessageAttachments
MessageReactions
MessageReceipts
MessageReadCursors
ConversationPins
ConversationSettings
GroupInvitations
Notifications
Calls
CallParticipants
```

Yêu cầu dữ liệu:

- Khóa chính rõ ràng.
- Index theo conversationId, sequence và createdAt.
- Unique constraint cho clientMessageId theo phạm vi phù hợp.
- Không lưu binary media trực tiếp trong bảng Messages.
- Hỗ trợ phân trang bằng cursor.
- Có chính sách xóa dữ liệu.
- Có migration database.
- Có backup và restore.

## 14. API backend

Các nhóm API tối thiểu:

```text
/api/auth
/api/users
/api/contacts
/api/friend-requests
/api/conversations
/api/conversations/{id}/messages
/api/messages/{id}
/api/messages/{id}/reactions
/api/messages/{id}/receipts
/api/groups
/api/uploads
/api/devices
/api/notifications
/api/calls
```

API cần có:

- Request/Response DTO rõ ràng.
- Pagination.
- Validation.
- Error code thống nhất.
- Idempotency cho thao tác gửi.
- Authentication/Authorization.
- OpenAPI/Swagger.
- Logging và tracing.
- Versioning khi cần.

## 15. Kiểm thử và chất lượng

### Unit Test

- Xử lý gửi tin nhắn.
- Xử lý tin nhắn trùng.
- Đồng bộ offline.
- Trạng thái đã đọc.
- Quản lý quyền nhóm.
- Riverpod Notifier.

### Widget Test

- Danh sách hội thoại.
- Bubble tin nhắn.
- Thanh nhập.
- Trạng thái loading/error.
- Dark Mode.

### Integration Test

- Đăng nhập.
- Gửi/nhận tin nhắn.
- Reconnect.
- Gửi ảnh.
- Chat nhóm.
- Push Notification.
- Đồng bộ nhiều thiết bị.

## 16. Các giai đoạn triển khai

### Giai đoạn 1 — Foundation

- Khởi tạo dự án.
- Cấu trúc Clean Architecture.
- Riverpod.
- Router.
- Theme và Design System.
- Network Layer.
- Authentication.
- Local Database.

### Giai đoạn 2 — Chat MVP

- Danh sách cuộc trò chuyện.
- Chat 1-1.
- Gửi/nhận văn bản realtime.
- Lịch sử tin nhắn.
- Trạng thái gửi/đọc.
- Badge chưa đọc.
- Đồng bộ offline cơ bản.

### Giai đoạn 3 — Chat nâng cao

- Gửi ảnh, video, file, voice.
- Reply, Forward, Reaction.
- Thu hồi/chỉnh sửa.
- Tìm kiếm.
- Chat nhóm.
- Danh bạ.

### Giai đoạn 4 — Hoàn thiện

- Push Notification.
- Quản lý nhiều thiết bị.
- Tối ưu hiệu năng.
- Dark Mode.
- Accessibility.
- Bảo mật.
- Monitoring và kiểm thử.

### Giai đoạn 5 — Mở rộng

- Gọi thoại/video.
- Nhật ký.
- E2EE nếu có yêu cầu và thiết kế phù hợp.
- Web/Desktop.
- Các tính năng doanh nghiệp.

## 17. Quy tắc bắt buộc dành cho AI Coding Agent

1. Đọc và tuân thủ cấu trúc dự án trước khi viết code.
2. Không tự ý thay đổi kiến trúc đã thống nhất.
3. Không viết toàn bộ ứng dụng trong một file.
4. Không đặt business logic trong Widget.
5. Không dùng dữ liệu giả trong production flow.
6. Không tự ý thêm dependency khi chưa đánh giá tương thích.
7. Không sử dụng API Flutter đã deprecated.
8. Không tạo lại Provider hoặc Service trùng chức năng.
9. Không tạo kết nối realtime riêng cho mỗi Widget.
10. Luôn xử lý loading, empty, error và retry.
11. Luôn kiểm tra null safety.
12. Code phải rõ ràng, dễ bảo trì, có khả năng test.
13. Ưu tiên tái sử dụng Widget và Design Token.
14. Không hardcode URL, token, khóa bảo mật.
15. Không bỏ qua các lỗi analyzer.
16. Không tự ý sửa code ngoài phạm vi yêu cầu.
17. Sau mỗi chức năng phải chạy format, analyze và các test liên quan.
18. Khi hoàn thành phải liệt kê file đã thay đổi và kết quả kiểm thử.
19. Với backend chưa tồn tại, phải định nghĩa API contract trước khi tích hợp.
20. Ưu tiên hoàn thành một chức năng chạy được từ đầu đến cuối thay vì tạo nhiều màn hình chưa có nghiệp vụ.

## 18. Tiêu chí nghiệm thu

Ứng dụng chỉ được xem là hoàn thành MVP khi:

- Hai tài khoản có thể nhắn tin cho nhau trên hai thiết bị thật.
- Tin nhắn được lưu trên backend.
- Tin nhắn hiển thị đúng thứ tự.
- Không bị trùng khi gửi lại hoặc reconnect.
- Có trạng thái gửi và đã đọc.
- Tải lịch sử tin nhắn bằng phân trang.
- Mất mạng và kết nối lại không làm mất tin nhắn đã lưu.
- Mở lại ứng dụng vẫn hiển thị lịch sử.
- Không phát sinh lỗi nghiêm trọng trong luồng đăng nhập và chat.
- Giao diện hoạt động tốt trên Android và iOS.
- Các bài kiểm thử cốt lõi đều đạt.

**Kết quả mong muốn:** Một ứng dụng Chat có giao diện và trải nghiệm chuyên nghiệp, kiến trúc bền vững, đồng bộ realtime đáng tin cậy, có thể mở rộng để phục vụ lượng người dùng lớn trong tương lai.
