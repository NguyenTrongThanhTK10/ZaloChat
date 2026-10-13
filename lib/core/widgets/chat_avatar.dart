import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 52,
    this.online = false,
    this.isGroup = false,
  });

  final String name;
  final String? imageUrl;
  final double size;
  final bool online;
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = imageUrl?.trim();
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();

    return Semantics(
      label: isGroup ? 'Ảnh nhóm $name' : 'Ảnh đại diện $name',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: size / 2,
              backgroundColor: scheme.primaryContainer,
              child: ClipOval(
                child: url == null || url.isEmpty
                    ? _fallback(context, initial)
                    : Image.network(
                        url,
                        width: size,
                        height: size,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _fallback(context, initial),
                      ),
              ),
            ),
            if (online)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: size * 0.25,
                  height: size * 0.25,
                  decoration: BoxDecoration(
                    color: AppColors.online,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context, String initial) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: isGroup
            ? Icon(
                Icons.groups_rounded,
                size: size * 0.43,
                color: theme.colorScheme.onPrimaryContainer,
              )
            : Text(
                initial,
                style: TextStyle(
                  fontSize: size * 0.36,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
      ),
    );
  }
}
