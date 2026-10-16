import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/api_exception.dart';
import '../../domain/entities/chat_message.dart';
import 'message_providers.dart';

class PickedChatAttachment {
  PickedChatAttachment({
    required this.path,
    required this.metadata,
    required this.kind,
  }) : clientMessageId = const Uuid().v4();

  final String path;
  final MessageAttachment metadata;
  final MessageKind kind;
  final String clientMessageId;
}

final attachmentServiceProvider = Provider((ref) => AttachmentService());

final attachmentFileProvider = FutureProvider.autoDispose
    .family<String, ChatMessage>(
      (ref, message) =>
          ref.watch(messageRepositoryProvider).downloadAttachment(message),
    );

class AttachmentService {
  Future<PickedChatAttachment?> pick({required bool image}) async {
    final result = await FilePicker.platform.pickFiles(
      type: image ? FileType.image : FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final selected = result.files.single;
    final path = selected.path;
    if (path == null) throw const ApiException('Không đọc được tệp đã chọn.');
    final size = await File(path).length();
    if (size == 0 || size > MessageAttachment.maxBytes) {
      throw const ApiException('Vui lòng chọn tệp từ 1 byte đến 20 MB.');
    }
    if (selected.name.length > 180) {
      throw const ApiException('Tên tệp tối đa 180 ký tự.');
    }
    return PickedChatAttachment(
      path: path,
      metadata: MessageAttachment(
        name: selected.name,
        size: size,
        contentType: 'application/octet-stream',
      ),
      kind: image ? MessageKind.image : MessageKind.file,
    );
  }

  Future<void> open(String path) async {
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw ApiException(
        result.type == ResultType.noAppToOpen
            ? 'Thiết bị chưa có ứng dụng mở loại tệp này.'
            : 'Không mở được tệp. Vui lòng thử lại.',
      );
    }
  }
}
