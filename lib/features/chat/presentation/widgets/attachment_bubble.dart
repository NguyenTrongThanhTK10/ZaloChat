import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exception.dart';
import '../../domain/entities/chat_message.dart';
import '../providers/attachment_providers.dart';
import '../providers/message_providers.dart';

class AttachmentBubble extends ConsumerStatefulWidget {
  const AttachmentBubble({
    super.key,
    required this.message,
    required this.isMine,
  });

  final ChatMessage message;
  final bool isMine;

  @override
  ConsumerState<AttachmentBubble> createState() => _AttachmentBubbleState();
}

class _AttachmentBubbleState extends ConsumerState<AttachmentBubble> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final message = widget.message;
    try {
      final path = message.kind == MessageKind.image
          ? await ref.read(attachmentFileProvider(message).future)
          : await ref
                .read(messageRepositoryProvider)
                .downloadAttachment(message);
      if (!mounted || widget.message.isRecalled) return;
      if (message.kind == MessageKind.image) {
        await showDialog<void>(
          context: context,
          useSafeArea: false,
          builder: (context) => Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: IconButton.filledTonal(
                        tooltip: 'Đóng ảnh',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        await ref.read(attachmentServiceProvider).open(path);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ApiException
                  ? error.message
                  : 'Chưa tải được tệp. Vui lòng thử lại.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final attachment = message.attachment;
    final scheme = Theme.of(context).colorScheme;
    final foreground = widget.isMine
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    if (attachment == null) {
      return Text(
        'Tệp không còn khả dụng',
        style: TextStyle(color: foreground),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.kind == MessageKind.image)
          Semantics(
            button: true,
            label: 'Mở ảnh ${attachment.name}',
            child: InkWell(
              key: ValueKey('attachment-${message.id}'),
              onTap: _opening ? null : _open,
              borderRadius: BorderRadius.circular(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ref
                    .watch(attachmentFileProvider(message))
                    .when(
                      data: (path) => Image.file(
                        File(path),
                        width: 240,
                        height: 180,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        errorBuilder: (_, _, _) => _imagePlaceholder(
                          foreground,
                          'Chạm để mở ảnh',
                          Icons.broken_image_outlined,
                        ),
                      ),
                      loading: () => SizedBox(
                        width: 240,
                        height: 180,
                        child: Center(
                          child: CircularProgressIndicator(color: foreground),
                        ),
                      ),
                      error: (_, _) => SizedBox(
                        width: 240,
                        height: 180,
                        child: Center(
                          child: TextButton.icon(
                            onPressed: () =>
                                ref.invalidate(attachmentFileProvider(message)),
                            icon: Icon(
                              Icons.refresh_rounded,
                              color: foreground,
                            ),
                            label: Text(
                              'Tải lại ảnh',
                              style: TextStyle(color: foreground),
                            ),
                          ),
                        ),
                      ),
                    ),
              ),
            ),
          )
        else
          InkWell(
            key: ValueKey('attachment-${message.id}'),
            onTap: _opening ? null : _open,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.insert_drive_file_outlined,
                    size: 32,
                    color: foreground,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          attachment.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          attachment.formattedSize,
                          style: TextStyle(
                            color: foreground.withValues(alpha: 0.75),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_opening)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: foreground,
                      ),
                    )
                  else
                    Icon(Icons.download_rounded, color: foreground, size: 22),
                ],
              ),
            ),
          ),
        if (message.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(message.text, style: TextStyle(color: foreground, height: 1.4)),
        ],
      ],
    );
  }

  Widget _imagePlaceholder(Color color, String label, IconData icon) =>
      SizedBox(
        width: 240,
        height: 180,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: color)),
          ],
        ),
      );
}
