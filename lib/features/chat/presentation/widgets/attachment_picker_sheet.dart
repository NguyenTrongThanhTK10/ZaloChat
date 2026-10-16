import 'package:flutter/material.dart';

enum AttachmentSource { image, file }

class AttachmentPickerSheet extends StatelessWidget {
  const AttachmentPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Đính kèm',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Đóng',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Material(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  _AttachmentOption(
                    source: AttachmentSource.image,
                    icon: Icons.photo_library_outlined,
                    title: 'Ảnh',
                    subtitle: 'Chọn ảnh từ thiết bị',
                    color: scheme.primary,
                  ),
                  const Divider(height: 1, indent: 72, endIndent: 16),
                  _AttachmentOption(
                    source: AttachmentSource.file,
                    icon: Icons.insert_drive_file_outlined,
                    title: 'Tệp đính kèm',
                    subtitle: 'Tài liệu và các loại tệp khác',
                    color: scheme.tertiary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  const _AttachmentOption({
    required this.source,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  final AttachmentSource source;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('attach-${source.name}'),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    leading: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: color),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => Navigator.pop(context, source),
  );
}
