import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

class AuthBrandPanel extends StatelessWidget {
  const AuthBrandPanel({super.key, this.expanded = false});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF183D79), Color(0xFF102952)]
              : const [Color(0xFF1264DD), Color(0xFF0848B0)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -100,
            right: -80,
            child: _Halo(size: expanded ? 360 : 240),
          ),
          Positioned(
            bottom: -180,
            left: -120,
            child: _Halo(size: expanded ? 420 : 300),
          ),
          Padding(
            padding: EdgeInsets.all(expanded ? 40 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.17),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: const Icon(
                        Icons.forum_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Lumi Chat',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 56),
                  Text(
                    'Gần nhau hơn,\nqua từng lời nhắn.',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Một nơi để chia sẻ mỗi ngày và giữ kết nối\nvới những người bạn yêu quý.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 36),
                ] else
                  const SizedBox(height: 12),
                Center(
                  child: SizedBox(
                    width: expanded ? 340 : 250,
                    height: expanded ? 200 : 94,
                    child: const _ChatIllustration(),
                  ),
                ),
                if (expanded) ...[
                  const SizedBox(height: 36),
                  Text(
                    'Mỗi cuộc trò chuyện đều có một khởi đầu.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Halo extends StatelessWidget {
  const _Halo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 30,
        ),
      ),
    );
  }
}

class _ChatIllustration extends StatelessWidget {
  const _ChatIllustration();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 320,
          height: 188,
          child: Stack(
            children: [
              Positioned(
                top: 5,
                right: 8,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 26,
                  color: const Color(0xFFB9D9FF).withValues(alpha: 0.9),
                ),
              ),
              Positioned(
                top: 18,
                left: 8,
                child: Transform.rotate(
                  angle: -0.08,
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                        bottomRight: Radius.circular(24),
                        bottomLeft: Radius.circular(6),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF042B71).withValues(alpha: 0.2),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            color: Color(0xFFE9F2FF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.waving_hand_rounded,
                            color: AppColors.blue,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _MessageLine(width: 68, color: Color(0xFF84B4F5)),
                              SizedBox(height: 10),
                              _MessageLine(width: 44, color: Color(0xFFD8E6F9)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 14,
                right: 12,
                child: Transform.rotate(
                  angle: 0.07,
                  child: Container(
                    width: 150,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 22,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFBBD9FF),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(22),
                        topRight: Radius.circular(22),
                        bottomLeft: Radius.circular(22),
                        bottomRight: Radius.circular(6),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF042B71)
                              .withValues(alpha: 0.15),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (var i = 0; i < 3; i++)
                          Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2D6CC3),
                              shape: BoxShape.circle,
                            ),
                          ),
                        const Icon(
                          Icons.favorite_rounded,
                          size: 20,
                          color: Color(0xFF2D6CC3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Positioned(
                bottom: 18,
                left: 42,
                child: Icon(
                  Icons.add_rounded,
                  size: 22,
                  color: Color(0xFF91BEFA),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageLine extends StatelessWidget {
  const _MessageLine({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(4),
    ),
  );
}
