import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/media/voice_playback.dart';
import '../../../../app/chat_preferences_provider.dart';
import '../../../../core/media/voice_recorder.dart';
import '../../../../core/media/speech_input.dart';
import '../../../../core/media/speech_input_provider.dart';
import '../../../../core/realtime/realtime_providers.dart';
import '../../../../core/realtime/realtime_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../../core/widgets/content_state.dart';
import '../../../../core/network/api_exception.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../conversations/domain/entities/conversation.dart';
import '../../../conversations/presentation/providers/conversation_providers.dart';
import '../../domain/entities/chat_message.dart';
import '../providers/message_providers.dart';
import '../providers/attachment_providers.dart';
import '../widgets/attachment_bubble.dart';
import '../widgets/attachment_picker_sheet.dart';
import '../widgets/message_actions_sheet.dart';
import '../widgets/pending_attachment_preview.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  MessageReply? _replyTo;
  final _scrollController = ScrollController();
  final _reactionBusy = <String>{};
  final _recallBusy = <String>{};
  bool _sending = false;
  bool _pickingAttachment = false;
  PickedChatAttachment? _pendingAttachment;
  String? _attachmentError;
  ({String text, MessageReply? replyTo})? _attachmentUpload;
  bool _showEmojiPicker = false;
  bool _showVoicePanel = false;
  bool _voiceAsText = false;
  bool _loadingOlder = false;
  bool _showLatestButton = false;
  int _lastMarkedSequence = 0;
  bool _isResumed = true;
  final VoiceRecorder _voiceRecorder = VoiceRecorder();
  VoicePlayback? _voicePlayback;
  VoiceRecording? _recordedVoice;
  String? _voiceClientMessageId;
  bool _recording = false;
  bool _voiceBusy = false;
  Duration _recordingElapsed = Duration.zero;
  Timer? _recordingTimer;
  late final SpeechInput _speechInput;
  bool _ownsSpeechInput = false;
  bool _startingSpeech = false;
  int _speechUiSession = 0;
  TextEditingValue? _lastSpeechValue;
  String? _lastSpeechError;

  bool get _speechActive => _startingSpeech || _speechInput.active;

  @override
  void initState() {
    super.initState();
    _speechInput = ref.read(speechInputProvider);
    _speechInput.addListener(_onSpeechChanged);
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      unawaited(_cancelSpeech());
      _lastSpeechError = null;
      _replyTo = null;
      _pendingAttachment = null;
      _attachmentError = null;
      _attachmentUpload = null;
      _showVoicePanel = false;
      _voiceAsText = false;
      unawaited(_discardVoice());
      _voicePlayback?.dispose();
      _voicePlayback = null;
      _lastMarkedSequence = 0;
      _showLatestButton = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _speechUiSession++;
    _speechInput.removeListener(_onSpeechChanged);
    if (_ownsSpeechInput || _startingSpeech) {
      unawaited(_speechInput.cancel());
    }
    _ownsSpeechInput = false;
    _recordingTimer?.cancel();
    unawaited(_disposeVoiceRecorder());
    if (_recordedVoice case final voice?) {
      unawaited(File(voice.path).delete().catchError((_) => File(voice.path)));
    }
    _voicePlayback?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _composerController.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _disposeVoiceRecorder() async {
    try {
      if (_recording) await _voiceRecorder.cancel();
      await _voiceRecorder.dispose();
    } catch (_) {
      // The route may close while the native recorder is already stopping.
    }
  }

  void _onScroll() {
    final show = _scrollController.offset > 180;
    if (show != _showLatestButton && mounted) {
      setState(() => _showLatestButton = show);
    }
    if (_scrollController.offset <= 72) {
      final current = ref.read(messagesProvider(widget.conversationId));
      final messages = current.asData?.value;
      if (messages != null) _markReadWhenNeeded(messages);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isResumed = state == AppLifecycleState.resumed;
    if (!_isResumed && _recording && !_voiceBusy) {
      unawaited(_finishVoice());
    }
    if (_ownsSpeechInput &&
        _speechInput.state == SpeechInputState.listening &&
        !_isResumed) {
      unawaited(_speechInput.stop());
    } else if (state == AppLifecycleState.paused && _startingSpeech) {
      unawaited(_cancelSpeech());
    }
    if (_isResumed) {
      final messages = ref
          .read(messagesProvider(widget.conversationId))
          .asData
          ?.value;
      if (messages != null) _markReadWhenNeeded(messages);
    }
  }

  Future<void> _sendMessage() async {
    if (_pendingAttachment != null) {
      await _sendAttachment();
      return;
    }
    await _sendText(_composerController.text, clearComposer: true);
  }

  Future<void> _openAttachments() async {
    if (_sending ||
        _voiceBusy ||
        _speechActive ||
        _recording ||
        _recordedVoice != null ||
        _pickingAttachment) {
      return;
    }
    final conversationId = widget.conversationId;
    _composerFocus.unfocus();
    setState(() {
      _pickingAttachment = true;
      _showVoicePanel = false;
      _showEmojiPicker = false;
    });
    try {
      final source = await showModalBottomSheet<AttachmentSource>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (_) => const AttachmentPickerSheet(),
      );
      if (!mounted ||
          widget.conversationId != conversationId ||
          source == null) {
        return;
      }
      final picked = await ref
          .read(attachmentServiceProvider)
          .pick(image: source == AttachmentSource.image);
      if (!mounted ||
          widget.conversationId != conversationId ||
          picked == null) {
        return;
      }
      setState(() {
        _pendingAttachment = picked;
        _attachmentError = null;
        _attachmentUpload = null;
      });
    } catch (error) {
      if (mounted && widget.conversationId == conversationId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ApiException
                  ? error.message
                  : 'Chưa chọn được tệp. Vui lòng thử lại.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  Future<void> _sendAttachment() async {
    final attachment = _pendingAttachment;
    if (attachment == null ||
        _sending ||
        _pickingAttachment ||
        _speechActive ||
        _voiceBusy) {
      return;
    }
    final text = _composerController.text.trim();
    if (text.length > 4000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chú thích tối đa 4.000 ký tự.')),
      );
      return;
    }
    final conversationId = widget.conversationId;
    final draft = _attachmentUpload ?? (text: text, replyTo: _replyTo);
    setState(() {
      _sending = true;
      _attachmentError = null;
      _attachmentUpload = draft;
    });
    try {
      await ref
          .read(messagesProvider(conversationId).notifier)
          .sendAttachment(
            attachment.path,
            attachment.metadata.name,
            attachment.kind,
            clientMessageId: attachment.clientMessageId,
            text: draft.text,
            replyTo: draft.replyTo,
          );
      if (!mounted || widget.conversationId != conversationId) return;
      setState(() {
        _pendingAttachment = null;
        _attachmentUpload = null;
        if (_composerController.text.trim() == draft.text) {
          _composerController.clear();
        }
        if (_replyTo?.id == draft.replyTo?.id) _replyTo = null;
      });
      if (_scrollController.hasClients) {
        unawaited(
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    } catch (error) {
      if (mounted && widget.conversationId == conversationId) {
        setState(
          () => _attachmentError = error is ApiException
              ? error.message
              : 'Chưa gửi được tệp. Vui lòng thử lại.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openVoicePanel() {
    if (_sending ||
        _voiceBusy ||
        _speechActive ||
        _pendingAttachment != null ||
        _pickingAttachment) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showEmojiPicker = false;
      _showVoicePanel = true;
    });
  }

  Future<void> _closeVoicePanel() async {
    if (_voiceBusy || _sending) return;
    if (_speechActive) await _cancelSpeech();
    if (_recording || _recordedVoice != null) await _discardVoice();
    if (mounted) setState(() => _showVoicePanel = false);
  }

  void _selectVoiceMode(bool asText) {
    if (_speechActive || _recording || _recordedVoice != null || _voiceBusy) {
      return;
    }
    setState(() {
      _voiceAsText = asText;
      _lastSpeechError = null;
    });
  }

  void _onSpeechChanged() {
    if (!mounted) return;
    if (_ownsSpeechInput) {
      if (_speechInput.value != _lastSpeechValue) {
        _lastSpeechValue = _speechInput.value;
        _composerController.value = _speechInput.value;
      }
      final error = _speechInput.error;
      if (error != null && error != _lastSpeechError) {
        _lastSpeechError = error;
      }
      if (!_speechInput.active && !_startingSpeech) _ownsSpeechInput = false;
    }
    setState(() {});
  }

  Future<void> _startSpeech() async {
    if (_speechActive ||
        _sending ||
        _voiceBusy ||
        _recording ||
        _recordedVoice != null) {
      return;
    }
    final session = ++_speechUiSession;
    final draft = _composerController.value;
    _ownsSpeechInput = true;
    _lastSpeechValue = draft;
    _lastSpeechError = null;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _startingSpeech = true;
      _showEmojiPicker = false;
    });
    try {
      await _voicePlayback?.pause();
      if (!mounted || session != _speechUiSession || !_isResumed) return;
      await _speechInput.start(draft);
    } catch (_) {
      if (mounted && session == _speechUiSession) {
        setState(
          () => _lastSpeechError =
              'Không mở được nhập tin bằng giọng nói. Vui lòng thử lại.',
        );
      }
    } finally {
      if (mounted && session == _speechUiSession) {
        setState(() => _startingSpeech = false);
        if (!_speechInput.active) _ownsSpeechInput = false;
      }
    }
  }

  Future<void> _cancelSpeech() async {
    if (!_ownsSpeechInput && !_startingSpeech) return;
    final session = ++_speechUiSession;
    if (mounted) setState(() => _startingSpeech = false);
    await _speechInput.cancel();
    if (session == _speechUiSession) _ownsSpeechInput = false;
  }

  Future<void> _startVoice() async {
    if (_voiceBusy || _recording || _speechActive) return;
    final conversationId = widget.conversationId;
    setState(() => _voiceBusy = true);
    try {
      await _voicePlayback?.pause();
      if (!mounted || widget.conversationId != conversationId) return;
      final allowed = await _voiceRecorder.start();
      if (!mounted || widget.conversationId != conversationId) {
        if (allowed) await _voiceRecorder.cancel();
        return;
      }
      if (!allowed) {
        _showVoiceError('Cần cho phép dùng micro để ghi âm.');
        return;
      }
      setState(() {
        _recording = true;
        _recordingElapsed = Duration.zero;
        _showEmojiPicker = false;
      });
      _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || !_recording) return;
        setState(() => _recordingElapsed = _voiceRecorder.elapsed);
        if (_recordingElapsed >= const Duration(seconds: 120)) {
          unawaited(_finishVoice());
        }
      });
    } catch (_) {
      if (mounted) _showVoiceError('Không bắt đầu ghi âm được.');
    } finally {
      if (mounted) setState(() => _voiceBusy = false);
    }
  }

  Future<void> _finishVoice() async {
    if (!_recording || _voiceBusy) return;
    _recordingTimer?.cancel();
    setState(() => _voiceBusy = true);
    try {
      final voice = await _voiceRecorder.stop();
      if (!mounted) return;
      if (voice == null || voice.durationMs < 1000) {
        if (voice != null) {
          await File(voice.path).delete();
        }
        _showVoiceError('Hãy ghi âm ít nhất 1 giây.');
      } else {
        setState(() {
          _recordedVoice = voice;
          _voiceClientMessageId = const Uuid().v4();
        });
      }
    } catch (_) {
      if (mounted) _showVoiceError('Không lưu được bản ghi âm.');
    } finally {
      if (mounted) {
        setState(() {
          _recording = false;
          _voiceBusy = false;
        });
      }
    }
  }

  Future<void> _discardVoice() async {
    _recordingTimer?.cancel();
    final wasRecording = _recording;
    final voice = _recordedVoice;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordedVoice = null;
        _voiceClientMessageId = null;
      });
    }
    try {
      if (wasRecording) await _voiceRecorder.cancel();
      if (voice != null) {
        final file = File(voice.path);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {
      if (mounted) _showVoiceError('Không hủy được bản ghi âm.');
    }
  }

  Future<void> _sendVoice() async {
    final voice = _recordedVoice;
    final clientMessageId = _voiceClientMessageId;
    if (voice == null || clientMessageId == null || _voiceBusy) return;
    setState(() => _voiceBusy = true);
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .sendVoice(
            voice.path,
            voice.durationMs,
            clientMessageId: clientMessageId,
            replyTo: _replyTo,
          );
      if (!mounted) return;
      setState(() {
        _recordedVoice = null;
        _voiceClientMessageId = null;
        _replyTo = null;
        _showVoicePanel = false;
      });
      final file = File(voice.path);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // The message was sent; temporary file cleanup can be skipped.
      }
      if (_scrollController.hasClients) {
        unawaited(
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        _showVoiceError('Không gửi được tin nhắn thoại. Nhấn gửi để thử lại.');
      }
    } finally {
      if (mounted) setState(() => _voiceBusy = false);
    }
  }

  Future<void> _toggleVoice(ChatMessage message) async {
    if (_speechActive || _recording || _voiceBusy) return;
    try {
      if (_voicePlayback == null) {
        setState(
          () => _voicePlayback = VoicePlayback(
            ref.read(messageRepositoryProvider),
          ),
        );
      }
      final playback = _voicePlayback!;
      await playback.toggle(message.id);
    } catch (_) {
      if (mounted) _showVoiceError('Không phát được tin nhắn thoại.');
    }
  }

  void _showVoiceError(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _sendText(String value, {bool clearComposer = false}) async {
    final text = value.trim();
    if (text.isEmpty || _sending || _speechActive) return;
    final replyTo = _replyTo;
    setState(() => _sending = true);
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .send(text, replyTo: replyTo);
      if (mounted && identical(_replyTo, replyTo)) {
        setState(() => _replyTo = null);
      }
      if (mounted && clearComposer && _composerController.text.trim() == text) {
        _composerController.clear();
        setState(() => _showVoicePanel = false);
      }
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không gửi được tin nhắn. Vui lòng thử lại.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _insertEmoji(String emoji) {
    final value = _composerController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final updated = value.text.replaceRange(start, end, emoji);
    _composerController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  Future<void> _showMessageActions(ChatMessage message, String? userId) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final conversationId = widget.conversationId;
    final canReact =
        userId != null &&
        message.sequence > 0 &&
        !message.isRecalled &&
        !_reactionBusy.contains(message.id);
    final canReply =
        userId != null &&
        message.sequence > 0 &&
        !message.isRecalled &&
        !_sending &&
        _attachmentUpload == null &&
        !_voiceBusy &&
        !_recording &&
        !_speechActive &&
        _recordedVoice == null;
    final canRecall =
        userId == message.senderId &&
        message.sequence > 0 &&
        !message.isRecalled &&
        !_recallBusy.contains(message.id);
    final selectedReactions = message.effectiveReactionSets[userId] ?? const [];
    final action = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      builder: (_) => MessageActionsSheet(
        message: message,
        selectedReactions: selectedReactions,
        isMine: userId == message.senderId,
        canReact: canReact,
        canReply: canReply,
        canRecall: canRecall,
      ),
    );
    if (!mounted || widget.conversationId != conversationId) return;
    switch (action) {
      case MessageReaction reaction:
        if (canReact) await _setReaction(message, userId, reaction);
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Đã sao chép tin nhắn')));
        }
      case MessageAction.reply:
        if (canReply) {
          setState(() {
            _replyTo = MessageReply.fromMessage(message);
            _showEmojiPicker = false;
          });
          _composerFocus.requestFocus();
        }
      case MessageAction.recall:
        if (canRecall) await _recallMessage(message);
      case null:
        break;
    }
  }

  Future<void> _recallMessage(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Thu hồi tin nhắn?'),
        content: const Text(
          'Nội dung tin nhắn sẽ không còn hiển thị với cả hai người.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Thu hồi'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _recallBusy.contains(message.id)) {
      return;
    }
    setState(() => _recallBusy.add(message.id));
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .recall(message);
      if (_replyTo?.id == message.id) setState(() => _replyTo = null);
      if (_voicePlayback?.messageId == message.id) {
        await _voicePlayback?.pause();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chưa thể thu hồi tin nhắn. Vui lòng thử lại.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _recallBusy.remove(message.id));
    }
  }

  Future<void> _setReaction(
    ChatMessage message,
    String userId,
    MessageReaction reaction,
  ) async {
    if (_reactionBusy.contains(message.id)) return;
    setState(() => _reactionBusy.add(message.id));
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .setReaction(
            message,
            reaction,
            selected: !(message.effectiveReactionSets[userId] ?? const [])
                .contains(reaction),
          );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chưa thể thả cảm xúc. Vui lòng thử lại.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reactionBusy.remove(message.id));
    }
  }

  Future<void> _retryMessage(String clientMessageId) async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .retry(clientMessageId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chưa thể gửi lại. Vui lòng thử sau.')),
        );
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    final provider = messagesProvider(widget.conversationId);
    if (!ref.read(provider.notifier).hasMore) return;
    setState(() => _loadingOlder = true);
    try {
      await ref.read(provider.notifier).loadOlder();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tải được tin nhắn cũ.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _markReadWhenNeeded(List<ChatMessage> messages) {
    if (!_isResumed || ModalRoute.of(context)?.isCurrent != true) return;
    if (_scrollController.hasClients && _scrollController.offset > 72) return;
    final currentUserId = ref.read(currentUserProvider)?.id;
    if (currentUserId == null) return;
    var latestIncomingSequence = _lastMarkedSequence;
    for (final message in messages) {
      if (message.senderId != currentUserId &&
          message.sequence > latestIncomingSequence) {
        latestIncomingSequence = message.sequence;
      }
    }
    if (latestIncomingSequence == _lastMarkedSequence) return;
    _lastMarkedSequence = latestIncomingSequence;
    unawaited(_markRead());
  }

  Future<void> _markRead() async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .markRead();
    } catch (_) {
      // The provider retains the unread state so a later update can retry.
      _lastMarkedSequence = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(conversationDetailProvider(widget.conversationId));
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final currentUserId = ref.watch(currentUserProvider)?.id;
    final connection = ref.watch(connectionStatusProvider).asData?.value;
    final conversation = detail.asData?.value;
    final theme = Theme.of(context);

    final visibleMessages = messages.asData?.value;
    if (visibleMessages != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markReadWhenNeeded(visibleMessages);
      });
    }

    ref.listen(messagesProvider(widget.conversationId), (previous, next) {
      final list = next.asData?.value;
      if (list == null) {
        return;
      }

      final playingId = _voicePlayback?.messageId;
      if (playingId != null &&
          list.any(
            (message) => message.id == playingId && message.isRecalled,
          )) {
        unawaited(_voicePlayback!.pause());
      }
      final replyId = _replyTo?.id;
      if (replyId != null &&
          list.any((message) => message.id == replyId && message.isRecalled)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _replyTo?.id == replyId) {
            setState(() => _replyTo = null);
          }
        });
      }

      final oldList = previous?.asData?.value;
      final receivedNewMessage =
          oldList != null &&
          oldList.isNotEmpty &&
          list.length > oldList.length &&
          list.last.clientMessageId != oldList.last.clientMessageId;
      if (receivedNewMessage &&
          _scrollController.hasClients &&
          _scrollController.offset > 180) {
        final oldExtent = _scrollController.position.maxScrollExtent;
        final oldOffset = _scrollController.offset;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) {
            return;
          }
          final newExtent = _scrollController.position.maxScrollExtent;
          final addedExtent = newExtent - oldExtent;
          if (addedExtent > 0) {
            _scrollController.jumpTo(
              math.min(oldOffset + addedExtent, newExtent),
            );
          }
        });
      }
      _markReadWhenNeeded(list);
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            if (conversation != null) ...[
              IconButton(
                tooltip: 'Xem thông tin ${conversation.title}',
                padding: EdgeInsets.zero,
                iconSize: 38,
                onPressed: () => context.push(
                  '/people/${Uri.encodeComponent(conversation.peerId)}',
                ),
                icon: ChatAvatar(
                  name: conversation.title,
                  imageUrl: conversation.avatarUrl,
                  size: 38,
                  online: conversation.isOnline == true,
                  isGroup: conversation.isGroup,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    conversation?.title ?? 'Tin nhắn',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (conversation?.isOnline == true)
                    Text(
                      'Đang hoạt động',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.online,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            children: [
              Expanded(
                child: detail.hasError
                    ? ContentState(
                        icon: Icons.error_outline_rounded,
                        title: 'Không mở được cuộc trò chuyện',
                        message: 'Vui lòng thử lại.',
                        actionLabel: 'Thử lại',
                        onAction: () => ref.invalidate(
                          conversationDetailProvider(widget.conversationId),
                        ),
                      )
                    : Stack(
                        children: [
                          messages.when(
                            loading: () => const _ChatMessagesSkeleton(),
                            error: (_, _) => ContentState(
                              icon: Icons.wifi_off_rounded,
                              title: 'Không tải được tin nhắn',
                              message: 'Kiểm tra kết nối rồi thử lại.',
                              actionLabel: 'Thử lại',
                              onAction: () => ref
                                  .read(
                                    messagesProvider(widget.conversationId)
                                        .notifier,
                                  )
                                  .refresh(),
                            ),
                            data: (items) => items.isEmpty
                                ? const ContentState(
                                    icon: Icons.chat_bubble_outline_rounded,
                                    title: 'Bắt đầu trò chuyện',
                                    message: 'Gửi lời chào để bắt đầu cuộc trò chuyện.',
                                  )
                                : _messageList(
                                    items,
                                    currentUserId,
                                    conversation,
                                  ),
                          ),
                          if (_showLatestButton && messages.hasValue)
                            Positioned(
                              right: AppSpacing.lg,
                              bottom: AppSpacing.lg,
                              child: FloatingActionButton.small(
                                heroTag: 'latest-message',
                                tooltip: 'Đến tin nhắn mới nhất',
                                onPressed: () => _scrollController.animateTo(
                                  0,
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                ),
                                child: const Icon(Icons.arrow_downward_rounded),
                              ),
                            ),
                        ],
                      ),
              ),
              if (connection == ConnectionStatus.disconnected)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_off_rounded, size: 16),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          'Ngoại tuyến · tin văn bản sẽ gửi lại khi có mạng',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              if (!detail.hasError) _composer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageList(
    List<ChatMessage> messages,
    String? currentUserId,
    Conversation? conversation,
  ) {
    final hasMore = ref
        .read(messagesProvider(widget.conversationId).notifier)
        .hasMore;
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      itemCount: messages.length + (hasMore ? 1 : 0),
      itemBuilder: (context, reverseIndex) {
        if (reverseIndex == messages.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: _loadingOlder
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: CircularProgressIndicator(),
                    )
                  : TextButton.icon(
                      onPressed: _loadOlder,
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Tải tin nhắn cũ'),
                    ),
            ),
          );
        }
        final index = messages.length - 1 - reverseIndex;
        final message = messages[index];
        final startsDay =
            index == 0 ||
            !_sameDay(
              messages[index - 1].createdAt.toLocal(),
              message.createdAt.toLocal(),
            );
        final isMine = message.senderId == currentUserId;
        final showPeerAvatar =
            !isMine &&
            (startsDay || messages[index - 1].senderId != message.senderId);
        return Column(
          children: [
            if (startsDay) _DayDivider(date: message.createdAt.toLocal()),
            _MessageBubble(
              message: message,
              onLongPress: () => _showMessageActions(message, currentUserId),
              currentUserId: currentUserId,
              isMine: isMine,
              showPeerAvatar: showPeerAvatar,
              peerName: conversation?.title ?? 'Người dùng',
              peerAvatarUrl: conversation?.avatarUrl,
              onHeart:
                  currentUserId != null &&
                      message.sequence > 0 &&
                      !message.isRecalled &&
                      !_reactionBusy.contains(message.id)
                  ? () => _showMessageActions(message, currentUserId)
                  : null,
              onRetry: message.status == MessageStatus.failed
                  ? () => _retryMessage(message.clientMessageId)
                  : null,
              playback: _voicePlayback,
              onPlayVoice:
                  message.kind == MessageKind.voice &&
                      !message.isRecalled &&
                      !_speechActive &&
                      !_recording &&
                      !_voiceBusy
                  ? () => _toggleVoice(message)
                  : null,
            ),
          ],
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_speechActive && _lastSpeechError != null)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                color: scheme.errorContainer,
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _lastSpeechError!,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Đóng thông báo giọng nói',
                      onPressed: () => setState(() => _lastSpeechError = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            if (_replyTo case final reply?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: _ReplyPreview(
                  reply: reply,
                  author: reply.senderId == ref.read(currentUserProvider)?.id
                      ? 'Bạn'
                      : ref
                                .read(
                                  conversationDetailProvider(
                                    widget.conversationId,
                                  ),
                                )
                                .asData
                                ?.value
                                .title ??
                            'Người dùng',
                  onCancel:
                      !_recording &&
                          _recordedVoice == null &&
                          !_voiceBusy &&
                          !_sending &&
                          _attachmentUpload == null
                      ? () => setState(() => _replyTo = null)
                      : null,
                  composer: true,
                ),
              ),
            if (_showVoicePanel) _voicePanel(context),
            if (_showEmojiPicker) _emojiPicker(context),
            if (_pendingAttachment case final attachment?)
              PendingAttachmentPreview(
                attachment: attachment,
                error: _attachmentError,
                retry: _attachmentUpload != null && !_sending,
                onRemove: _sending
                    ? null
                    : () => setState(() {
                        _pendingAttachment = null;
                        _attachmentError = null;
                        _attachmentUpload = null;
                      }),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: _showEmojiPicker
                        ? 'Đóng biểu tượng cảm xúc'
                        : 'Chọn biểu tượng cảm xúc',
                    onPressed:
                        _speechActive ||
                            _recording ||
                            _recordedVoice != null ||
                            _attachmentUpload != null ||
                            _pickingAttachment
                        ? null
                        : () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            setState(() {
                              _showVoicePanel = false;
                              _showEmojiPicker = !_showEmojiPicker;
                            });
                          },
                    icon: Icon(
                      _showEmojiPicker
                          ? Icons.keyboard_rounded
                          : Icons.emoji_emotions_outlined,
                      color: scheme.primary,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      readOnly:
                          _speechActive ||
                          _recording ||
                          _recordedVoice != null ||
                          _attachmentUpload != null,
                      focusNode: _composerFocus,
                      controller: _composerController,
                      onTap: () {
                        if (_showEmojiPicker ||
                            (_showVoicePanel &&
                                !_speechActive &&
                                !_recording &&
                                _recordedVoice == null)) {
                          setState(() {
                            _showEmojiPicker = false;
                            _showVoicePanel = false;
                          });
                        }
                      },
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: _pendingAttachment == null
                            ? 'Tin nhắn'
                            : 'Thêm chú thích...',
                        isDense: true,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _composerController,
                    builder: (context, value, child) =>
                        value.text.trim().isEmpty && _pendingAttachment == null
                        ? child!
                        : const SizedBox.shrink(),
                    child: IconButton(
                      key: const ValueKey('open-voice-panel'),
                      tooltip: _showVoicePanel ? 'Đóng ghi âm' : 'Mở ghi âm',
                      onPressed:
                          _sending ||
                              _pickingAttachment ||
                              _voiceBusy ||
                              _speechActive ||
                              _recording ||
                              _recordedVoice != null
                          ? null
                          : _showVoicePanel
                          ? _closeVoicePanel
                          : _openVoicePanel,
                      icon: Icon(
                        _showVoicePanel
                            ? Icons.keyboard_voice_rounded
                            : Icons.mic_none_rounded,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _composerController,
                    builder: (context, value, _) {
                      final canSend =
                          value.text.trim().isNotEmpty ||
                          _pendingAttachment != null;
                      return IconButton.filled(
                        tooltip: _pendingAttachment != null
                            ? 'Gửi tệp đính kèm'
                            : canSend
                            ? 'Gửi tin nhắn'
                            : 'Đính kèm ảnh hoặc tệp',
                        onPressed:
                            _sending ||
                                _pickingAttachment ||
                                _voiceBusy ||
                                _speechActive ||
                                _recording ||
                                _recordedVoice != null
                            ? null
                            : canSend
                            ? _sendMessage
                            : _openAttachments,
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                canSend
                                    ? Icons.send_rounded
                                    : Icons.attach_file_rounded,
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voicePanel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listening = _speechInput.state == SpeechInputState.listening;
    final speechStarting =
        _startingSpeech || _speechInput.state == SpeechInputState.starting;
    final speechFinishing = _speechInput.state == SpeechInputState.finishing;
    final busy = _voiceBusy || speechStarting || speechFinishing;
    final active = _voiceAsText ? _speechActive : _recording;
    final seconds = _recording
        ? _recordingElapsed.inSeconds
        : (_recordedVoice?.durationMs ?? 0) ~/ 1000;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'Ghi âm',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Đóng bảng ghi âm',
                onPressed: busy ? null : _closeVoicePanel,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _voiceModeButton('Gửi bản ghi âm', false),
              const SizedBox(width: 8),
              _voiceModeButton('Gửi dạng văn bản', true),
            ],
          ),
          const SizedBox(height: 16),
          if (_recordedVoice != null) ...[
            Row(
              children: [
                Icon(Icons.graphic_eq_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: _VoiceBars(
                    color: scheme.primary,
                    progress: 0,
                    height: 30,
                  ),
                ),
                const SizedBox(width: 10),
                Text(_voiceTime(seconds), style: theme.textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _voiceBusy ? null : _discardVoice,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Xóa'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _voiceBusy ? null : _sendVoice,
                  icon: _voiceBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                  label: const Text('Gửi bản ghi âm'),
                ),
              ],
            ),
          ] else ...[
            if (_voiceAsText && _composerController.text.trim().isNotEmpty)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 84),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _composerController.text,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            if (_voiceAsText && _composerController.text.trim().isNotEmpty)
              const SizedBox(height: 12),
            if (_recording)
              Text(
                '${_voiceTime(seconds)} / 02:00',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (_recording) const SizedBox(height: 12),
            Semantics(
              button: true,
              label: active ? 'Dừng ghi âm' : 'Bấm để ghi âm',
              child: InkWell(
                key: const ValueKey('voice-record-button'),
                onTap: busy
                    ? null
                    : _voiceAsText
                    ? listening
                          ? _speechInput.stop
                          : _speechActive
                          ? null
                          : _startSpeech
                    : _recording
                    ? _finishVoice
                    : _startVoice,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? scheme.error : scheme.primary,
                    boxShadow: [
                      BoxShadow(
                        color: (active ? scheme.error : scheme.primary)
                            .withValues(alpha: 0.22),
                        blurRadius: 0,
                        spreadRadius: 7,
                      ),
                    ],
                  ),
                  child: busy
                      ? Padding(
                          padding: const EdgeInsets.all(29),
                          child: CircularProgressIndicator(
                            color: scheme.onPrimary,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Icon(
                          active ? Icons.stop_rounded : Icons.mic_rounded,
                          color: scheme.onPrimary,
                          size: 38,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _voiceAsText
                  ? speechStarting
                        ? 'Đang mở nhận dạng giọng nói…'
                        : speechFinishing
                        ? 'Đang hoàn tất văn bản…'
                        : listening
                        ? 'Đang nghe · ${_speechInput.languageName}'
                        : 'Bấm để nói, sau đó sửa văn bản trước khi gửi'
                  : _recording
                  ? 'Bấm để dừng ghi âm'
                  : 'Bấm để ghi âm tin nhắn thoại',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (_speechActive) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _cancelSpeech,
                child: const Text('Hủy nhập giọng nói'),
              ),
            ],
            if (_recording) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _voiceBusy ? null : _discardVoice,
                child: const Text('Hủy ghi âm'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _voiceModeButton(String label, bool asText) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _voiceAsText == asText;
    return Flexible(
      child: ChoiceChip(
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: selected,
        onSelected:
            _speechActive || _recording || _recordedVoice != null || _voiceBusy
            ? null
            : (_) => _selectVoiceMode(asText),
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  String _voiceTime(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  Widget _emojiPicker(BuildContext context) {
    final theme = Theme.of(context);
    const emojis = [
      '😀',
      '😁',
      '🥰',
      '😍',
      '😘',
      '😎',
      '😂',
      '🤣',
      '😊',
      '😉',
      '🤔',
      '😭',
      '😢',
      '😮',
      '😡',
      '🥳',
      '❤️',
      '🧡',
      '💙',
      '💚',
      '👍',
      '👏',
      '🙏',
      '🔥',
      '🎉',
      '✨',
      '🌹',
      '☕',
      '💯',
      '👌',
      '🙌',
      '👋',
    ];
    return Container(
      width: double.infinity,
      height: 212,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              bottom: AppSpacing.sm,
            ),
            child: Text(
              'Biểu tượng cảm xúc',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: GridView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: emojis.length,
              itemBuilder: (context, index) => InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _insertEmoji(emojis[index]),
                child: Center(
                  child: Text(
                    emojis[index],
                    style: const TextStyle(fontSize: 27),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? 'Hôm nay'
        : day == today.subtract(const Duration(days: 1))
        ? 'Hôm qua'
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.reply,
    required this.author,
    this.onCancel,
    this.composer = false,
  });

  final MessageReply reply;
  final String author;
  final VoidCallback? onCancel;
  final bool composer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  composer ? 'Đang trả lời $author' : author,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  reply.kind == MessageKind.voice
                      ? '🎤 Tin nhắn thoại'
                      : reply.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (composer)
            IconButton(
              tooltip: 'Hủy trả lời',
              onPressed: onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.message,
    required this.onLongPress,
    this.currentUserId,
    required this.isMine,
    required this.showPeerAvatar,
    required this.peerName,
    this.peerAvatarUrl,
    this.onHeart,
    this.onRetry,
    this.playback,
    this.onPlayVoice,
  });

  final ChatMessage message;
  final VoidCallback onLongPress;
  final String? currentUserId;
  final bool isMine;
  final bool showPeerAvatar;
  final String peerName;
  final String? peerAvatarUrl;
  final VoidCallback? onHeart;
  final VoidCallback? onRetry;
  final VoicePlayback? playback;
  final VoidCallback? onPlayVoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final timestamp = message.createdAt.toLocal();
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final status = switch (message.status) {
      MessageStatus.sending => (
        'Đang gửi',
        Icons.schedule_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.sent => (
        'Đã gửi',
        Icons.check_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.delivered => (
        'Đã nhận',
        Icons.done_all_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.read => ('Đã xem', Icons.done_all_rounded, scheme.primary),
      MessageStatus.failed => (
        'Gửi thất bại',
        Icons.error_outline_rounded,
        scheme.error,
      ),
    };
    final reactionCounts = <MessageReaction, int>{};
    for (final selected in message.effectiveReactionSets.values) {
      for (final reaction in selected.toSet()) {
        reactionCounts.update(
          reaction,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final reactionTotal = reactionCounts.values.fold<int>(
      0,
      (sum, count) => sum + count,
    );
    final visibleReactions = MessageReaction.values
        .where(reactionCounts.containsKey)
        .toList(growable: false);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            SizedBox(
              width: 32,
              height: 32,
              child: showPeerAvatar
                  ? Tooltip(
                      message: 'Xem thông tin $peerName',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => context.push(
                          '/people/${Uri.encodeComponent(message.senderId)}',
                        ),
                        child: ChatAvatar(
                          name: peerName,
                          imageUrl: peerAvatarUrl,
                          size: 32,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    math.min(MediaQuery.sizeOf(context).width, 620) * 0.78,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: isMine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: reactionTotal == 0 || message.isRecalled
                                ? 0
                                : 14,
                          ),
                          child: GestureDetector(
                            key: ValueKey('message-${message.id}'),
                            onLongPress: onLongPress,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.md,
                              ),
                              decoration: BoxDecoration(
                                color: isMine
                                    ? scheme.primaryContainer
                                    : scheme.surface,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(20),
                                  topRight: const Radius.circular(20),
                                  bottomLeft: Radius.circular(isMine ? 20 : 6),
                                  bottomRight: Radius.circular(isMine ? 6 : 20),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!message.isRecalled &&
                                      message.replyTo != null) ...[
                                    _ReplyPreview(
                                      reply: message.replyTo!,
                                      author:
                                          message.replyTo!.senderId ==
                                              currentUserId
                                          ? 'Bạn'
                                          : peerName,
                                    ),
                                    const SizedBox(height: AppSpacing.sm),
                                  ],
                                  if (message.isRecalled)
                                    Text(
                                      'Tin nhắn đã thu hồi',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: isMine
                                                ? scheme.onPrimaryContainer
                                                      .withValues(alpha: 0.75)
                                                : scheme.onSurfaceVariant,
                                          ),
                                    )
                                  else if (message.kind == MessageKind.voice)
                                    _VoiceBubble(
                                      message: message,
                                      playback: playback,
                                      onPlay: onPlayVoice,
                                      isMine: isMine,
                                    )
                                  else if (message.kind == MessageKind.image ||
                                      message.kind == MessageKind.file)
                                    AttachmentBubble(
                                      message: message,
                                      isMine: isMine,
                                    )
                                  else
                                    Text(
                                      message.text,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontSize: switch (ref.watch(
                                              messageTextSizeProvider,
                                            )) {
                                              MessageTextSize.small => 12,
                                              MessageTextSize.normal => 14,
                                              MessageTextSize.large => 18,
                                            },
                                            color: isMine
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurface,
                                            height: 1.4,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (!message.isRecalled && reactionTotal > 0)
                          Positioned(
                            right: 6,
                            bottom: 0,
                            child: Tooltip(
                              message: 'Đổi cảm xúc',
                              child: Material(
                                key: ValueKey('message-hearts-${message.id}'),
                                color: scheme.surface,
                                elevation: 1,
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: onHeart,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (final (index, reaction)
                                            in visibleReactions.indexed) ...[
                                          if (index > 0)
                                            const SizedBox(width: 3),
                                          MessageReactionIcon(reaction),
                                        ],
                                        if (reactionTotal > 1) ...[
                                          const SizedBox(width: 4),
                                          Text(
                                            '$reactionTotal',
                                            style: theme.textTheme.labelSmall,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          time,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Icon(status.$2, size: 15, color: status.$3),
                          const SizedBox(width: 3),
                          Text(
                            status.$1,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: status.$3,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (isMine && onRetry != null)
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Gửi lại'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceBubble extends StatelessWidget {
  const _VoiceBubble({
    required this.message,
    required this.isMine,
    this.playback,
    this.onPlay,
  });

  final ChatMessage message;
  final bool isMine;
  final VoicePlayback? playback;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final durationMs = message.voiceDurationMs ?? 0;
    final totalSeconds = (durationMs / 1000).ceil();
    final scheme = Theme.of(context).colorScheme;
    final foreground = isMine ? scheme.onPrimaryContainer : scheme.primary;
    return ListenableBuilder(
      listenable: playback ?? const _SilentListenable(),
      builder: (context, _) {
        final current = playback?.messageId == message.id;
        final loading = current && playback!.loading;
        final playing = current && playback!.isPlaying;
        final progress = current && durationMs > 0
            ? (playback!.position.inMilliseconds / durationMs).clamp(0.0, 1.0)
            : 0.0;
        return SizedBox(
          width: 188,
          child: Row(
            children: [
              Tooltip(
                message: playing
                    ? 'Tạm dừng tin nhắn thoại'
                    : 'Phát tin nhắn thoại',
                triggerMode: TooltipTriggerMode.manual,
                child: IconButton(
                  onPressed: onPlay,
                  icon: loading
                      ? SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: foreground,
                          ),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: foreground,
                          size: 30,
                        ),
                ),
              ),
              Expanded(
                child: _VoiceBars(
                  color: foreground,
                  progress: progress,
                  height: 28,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${totalSeconds}s',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VoiceBars extends StatelessWidget {
  const _VoiceBars({
    required this.color,
    required this.progress,
    required this.height,
  });

  final Color color;
  final double progress;
  final double height;

  static const _heights = <double>[
    .32,
    .58,
    .84,
    .43,
    .70,
    1,
    .55,
    .37,
    .76,
    .92,
    .48,
    .67,
    .36,
    .86,
    .62,
    .42,
    .94,
    .72,
    .38,
    .64,
    .80,
    .46,
    .59,
    .34,
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var index = 0; index < _heights.length; index++)
          Expanded(
            child: Center(
              child: Container(
                height: height * _heights[index],
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: color.withValues(
                    alpha: index / _heights.length <= progress ? 1 : .45,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _SilentListenable extends Listenable {
  const _SilentListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _ChatMessagesSkeleton extends StatelessWidget {
  const _ChatMessagesSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _placeholder(color, Alignment.centerLeft, 180),
          _placeholder(color, Alignment.centerRight, 220),
          _placeholder(color, Alignment.centerLeft, 130),
          _placeholder(color, Alignment.centerRight, 190),
        ],
      ),
    );
  }

  Widget _placeholder(Color color, Alignment alignment, double width) {
    return Align(
      alignment: alignment,
      child: Container(
        width: width,
        height: 52,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}
