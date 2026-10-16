import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/avatar_provider.dart';
import '../theme/app_theme.dart';

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.imageProvider,
    this.size = 52,
    this.online = false,
    this.isGroup = false,
  });

  final String name;
  final String? imageUrl;
  final ImageProvider? imageProvider;
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
                child: imageProvider != null
                    ? Image(
                        image: imageProvider!,
                        width: size,
                        height: size,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _fallback(context, initial),
                      )
                    : url != null &&
                          url.startsWith('/api/users/') &&
                          url.contains('/avatar/')
                    ? Consumer(
                        builder: (context, ref, _) => ref
                            .watch(avatarBytesProvider(url))
                            .when(
                              data: (bytes) => Image.memory(
                                bytes,
                                width: size,
                                height: size,
                                fit: BoxFit.cover,
                                cacheWidth:
                                    (size *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round()
                                        .clamp(1, 512),
                                errorBuilder: (_, _, _) =>
                                    _fallback(context, initial),
                              ),
                              loading: () => _fallback(context, initial),
                              error: (_, _) => _fallback(context, initial),
                            ),
                      )
                    : url == null || url.isEmpty
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
