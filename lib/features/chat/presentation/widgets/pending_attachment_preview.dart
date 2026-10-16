import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/entities/chat_message.dart';
import '../providers/attachment_providers.dart';

class PendingAttachmentPreview extends StatelessWidget {
  const PendingAttachmentPreview({
    super.key,
    required this.attachment,
    required this.onRemove,
    this.retry = false,
    this.error,
  });

  final PickedChatAttachment attachment;
  final VoidCallback? onRemove;
  final bool retry;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: attachment.kind == MessageKind.image
                ? Image.file(
                    File(attachment.path),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    cacheWidth: 168,
                    errorBuilder: (_, _, _) => SizedBox(
                      width: 56,
                      height: 56,
                      child: Icon(Icons.image_outlined, color: scheme.primary),
                    ),
                  )
                : SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(
                      Icons.insert_drive_file_outlined,
                      color: scheme.primary,
                      size: 32,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.metadata.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  retry
                      ? 'Chưa gửi · Bấm gửi để thử lại'
                      : attachment.metadata.formattedSize,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (error case final message?) ...[
                  const SizedBox(height: 4),
                  Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Bỏ tệp đính kèm',
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
