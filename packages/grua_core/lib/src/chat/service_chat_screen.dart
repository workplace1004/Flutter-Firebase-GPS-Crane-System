import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../calls/call_controller.dart';
import '../domain/enums.dart';
import '../domain/failures.dart';
import '../domain/models/chat_prefs.dart';
import '../domain/models/dispatch_models.dart';
import '../domain/repositories.dart';
import '../media/photo_picker.dart';
import '../providers.dart';
import '../theme/brand.dart';
import '../theme/widgets/brand_widgets.dart';
import '../theme/widgets/driver_avatar.dart';
import '../utils/date_time_do.dart';

/// Chat between the customer and the assigned chofer of a job, in both apps.
///
/// Messages are written straight to Firestore rather than through a callable,
/// so they land instantly; the rules restrict who may post and a trigger sends
/// the push. Quick replies exist because at least one side is driving.
///
/// [role] is who is holding the phone: it decides whose name is in the title,
/// which quick replies are offered, and the role stamped on each message.
class ServiceChatScreen extends ConsumerWidget {
  const ServiceChatScreen({
    required this.serviceId,
    required this.role,
    super.key,
  });

  final String serviceId;
  final UserRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDriver = role == UserRole.driver;
    final uid = ref.watch(currentUserIdProvider);
    final service = ref.watch(serviceByIdProvider(serviceId)).value;
    final messages =
        ref.watch(serviceMessagesProvider(serviceId)).value ?? const [];

    // The person on the other end of the conversation.
    final otherName =
        (isDriver ? service?.clientName : service?.driverName) ?? '';
    final otherUid = (isDriver ? service?.clientId : service?.driverId) ?? '';

    // What this person did to this conversation: their own doing, on their own
    // screen. The other side sees none of it.
    final threadKey = jobThreadKey(serviceId);
    final prefs =
        ref.watch(chatThreadPrefsProvider(threadKey)).value ?? ChatThreadPrefs.none;
    final blocked =
        ref.watch(blockedUsersProvider).value?.contains(otherUid) ?? false;
    final blockedByOther =
        ref.watch(blockedByProvider(otherUid)).value ?? false;

    return ChatThreadView(
      title: otherName.isNotEmpty
          ? otherName
          : (isDriver ? 'Cliente' : 'Chofer'),
      // Only the chofer has a stored photo; the customer's face falls back to
      // their initials, which is what the avatar draws without a URL.
      photoUrl: isDriver ? '' : (service?.driverPhotoUrl ?? ''),
      // On a job the two sides already have each other's number.
      phoneNumber: (isDriver ? service?.clientPhone : service?.driverPhone) ?? '',
      // The same in-app call as the phone button on the service screen, so the
      // header's call icon rings the other person's app — in a browser too,
      // where handing a number to the dialer did nothing at all. Outside the
      // window where the two are in contact, the call screen says why it
      // cannot ring.
      onCall: service == null
          ? null
          : () => unawaited(
                ref.read(callControllerProvider.notifier).call(
                      serviceId: serviceId,
                      peerName: otherName,
                    ),
              ),
      onVideoCall: service == null
          ? null
          : () => unawaited(
                ref.read(callControllerProvider.notifier).call(
                      serviceId: serviceId,
                      peerName: otherName,
                      video: true,
                    ),
              ),
      hiddenBefore: prefs.clearedAt,
      blocked: blocked,
      blockedByOther: blockedByOther,
      onSetBlocked: uid == null || otherUid.isEmpty
          ? null
          : ({required blocked}) => ref
                .read(chatPrefsRepositoryProvider)
                .setBlocked(uid: uid, otherUid: otherUid, blocked: blocked),
      onClearChat: uid == null
          ? null
          : () => ref
                .read(chatPrefsRepositoryProvider)
                .clearThread(uid: uid, threadKey: threadKey),
      onDeleteChat: uid == null
          ? null
          : () => ref
                .read(chatPrefsRepositoryProvider)
                .deleteThread(uid: uid, threadKey: threadKey),
      subtitle: service?.status.label,
      messages: messages,
      myUid: uid,
      canWrite: service?.canChat ?? false,
      closedNotice: 'El chat se cierra cuando termina el servicio.',
      emptyMessage: isDriver
          ? 'Escríbele al cliente si necesitas alguna indicación para '
                'encontrarlo.'
          : 'Escríbele al chofer si necesitas darle alguna indicación.',
      photoPicker: ref.watch(photoPickerProvider),
      otherTyping:
          ref.watch(otherTypingProvider(jobThreadKey(serviceId))).value ??
          false,
      onTyping: uid == null
          ? null
          : (typing) => unawaited(
              ref
                  .read(typingRepositoryProvider)
                  .setTyping(
                    threadKey: jobThreadKey(serviceId),
                    uid: uid,
                    typing: typing,
                  ),
            ),
      onSendImage: uid == null
          ? null
          : (photo, clientMsgId) async {
              final chat = ref.read(chatRepositoryProvider);
              final upload = await chat.uploadImage(
                serviceId: serviceId,
                bytes: photo.bytes,
                contentType: photo.contentType,
              );
              final url = upload.valueOrNull;
              if (url == null) {
                return Result.err(
                  upload.failureOrNull ?? const Failure(FailureCode.unknown),
                );
              }
              final sent = await chat.sendMessage(
                serviceId: serviceId,
                senderId: uid,
                senderRole: role,
                text: '',
                clientMsgId: clientMsgId,
                imageUrl: url,
              );
              return sent;
            },
      onSend: (text, clientMsgId) {
        if (uid == null) {
          return Future.value(
            const Result.err(Failure(FailureCode.unauthenticated)),
          );
        }
        return ref
            .read(chatRepositoryProvider)
            .sendMessage(
              serviceId: serviceId,
              senderId: uid,
              senderRole: role,
              text: text,
              clientMsgId: clientMsgId,
            );
      },
      onDeleteMessages: uid == null
          ? null
          : (ids) => ref
                .read(chatRepositoryProvider)
                .deleteMessages(
                  serviceId: serviceId,
                  senderId: uid,
                  messageIds: ids,
                ),
      onDownloadImages: openChatImages,
      onMarkRead: uid == null
          ? null
          : () => ref.read(chatRepositoryProvider).markRead(serviceId, uid),
    );
  }
}

/// A conversation on screen: bubbles, quick replies and the composer.
///
/// Shared by a job's chat and a chat request's, which differ only in where
/// the messages live and when writing is allowed. Having the thread open is
/// what reading it means, so the other side's messages are marked read as
/// they arrive — that is what clears the badges elsewhere.
class ChatThreadView extends StatefulWidget {
  const ChatThreadView({
    required this.title,
    required this.messages,
    required this.myUid,
    required this.canWrite,
    required this.closedNotice,
    required this.emptyMessage,
    required this.onSend,
    this.subtitle,
    this.photoUrl = '',
    this.phoneNumber = '',
    this.onCall,
    this.onVideoCall,
    this.hiddenBefore,
    this.blocked = false,
    this.blockedByOther = false,
    this.onSetBlocked,
    this.onClearChat,
    this.onDeleteChat,
    this.onMarkRead,
    this.banner,
    this.actions = const [],
    this.photoPicker,
    this.onSendImage,
    this.otherTyping = false,
    this.onTyping,
    this.onDeleteMessages,
    this.onDownloadImages,
    super.key,
  });

  final String title;
  final String? subtitle;

  /// The other person's face in the header. Empty draws their initials.
  final String photoUrl;

  /// Who the call button dials, when there is no [onCall]. Empty says we do
  /// not have their number yet.
  final String phoneNumber;

  /// Places an in-app voice call. When given, the call button uses it instead
  /// of handing [phoneNumber] to the phone's dialer. The job chat passes one;
  /// a chat with a nearby truck before any job has no service to call through,
  /// and keeps the dialer.
  final VoidCallback? onCall;

  /// Places an in-app video call. Only a job chat has one: a call runs through
  /// a service, and a chat with a nearby truck has none yet.
  final VoidCallback? onVideoCall;

  /// This person emptied the conversation up to here: messages sent at or
  /// before it are theirs to not see again. Nothing is removed for the other
  /// side — see [onClearChat].
  final DateTime? hiddenBefore;

  /// This person blocked the other one. They can still read the history, and
  /// the composer says why it is gone.
  final bool blocked;

  /// The other person blocked *them*. Writing is refused by the rules, so the
  /// screen says so instead of letting a message fail on its way out.
  final bool blockedByOther;

  /// Blocks or unblocks the other person. Without it the menu offers neither.
  final Future<Result<void>> Function({required bool blocked})? onSetBlocked;

  /// Empties this conversation, and empties-and-hides it, for this person
  /// only. Without them the menu offers neither.
  final Future<Result<void>> Function()? onClearChat;
  final Future<Result<void>> Function()? onDeleteChat;

  final List<ChatMessage> messages;
  final String? myUid;

  /// Whether the composer shows. When not, [closedNotice] says why.
  final bool canWrite;
  final String closedNotice;
  final String emptyMessage;
  final Future<Result<void>> Function(String text, String clientMsgId) onSend;
  final Future<Object?> Function()? onMarkRead;

  /// Shown above the messages — an answer to give, or one being waited for.
  final Widget? banner;
  final List<Widget> actions;

  /// How a photo comes off the phone. With [onSendImage], puts a clip on the
  /// composer; without either, the conversation is words only.
  final PhotoPicker? photoPicker;
  final Future<Result<void>> Function(PickedPhoto photo, String clientMsgId)?
  onSendImage;

  /// The other side is typing right now: says so in place of the subtitle.
  final bool otherTyping;

  /// Called as this side starts and stops typing. Throttled here, so it is
  /// safe to write straight to the backend from it.
  final ValueChanged<bool>? onTyping;

  /// Retracts messages for both sides — either side's, since a conversation
  /// belongs to the two people in it.
  final Future<Result<void>> Function(List<String> messageIds)?
  onDeleteMessages;

  /// Hands the selected photos to the platform to save or open.
  final Future<void> Function(List<String> imageUrls)? onDownloadImages;

  @override
  State<ChatThreadView> createState() => _ChatThreadViewState();
}

class _ChatThreadViewState extends State<ChatThreadView> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  var _sending = false;

  /// A markRead is in flight; the stream echoes each stamp, and without this
  /// every echo would start another one.
  var _markingRead = false;

  /// The messages picked out by a long press. Empty means ordinary reading.
  final _selected = <String>{};

  /// Looking for something said earlier: the header becomes a search box and
  /// the list narrows to what matches.
  final _search = TextEditingController();
  var _searching = false;

  /// Picking messages out, whether or not anything is ticked yet: the menu
  /// can start the mode with nothing chosen.
  var _selectionMode = false;

  bool get _selecting => _selectionMode;

  /// When this side last said it was typing, and the timer that takes it back.
  ///
  /// Typing is announced at most every [_typingPing] and withdrawn after
  /// [_typingIdle] of quiet, so a long message costs a handful of writes
  /// rather than one per keystroke.
  static const _typingPing = Duration(seconds: 4);
  static const _typingIdle = Duration(seconds: 3);
  DateTime? _typingSince;
  Timer? _typingStop;

  @override
  void initState() {
    super.initState();
    _scheduleMarkRead();
  }

  @override
  void didUpdateWidget(ChatThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) _scheduleMarkRead();
  }

  @override
  void dispose() {
    // Leaving the screen is not typing. Said before the state goes, so the
    // other side's indicator does not hang on an empty conversation.
    _typingStop?.cancel();
    if (_typingSince != null) widget.onTyping?.call(false);
    _controller.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onComposerChanged(String value) {
    if (widget.onTyping == null) return;
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }

    final now = DateTime.now();
    if (_typingSince == null || now.difference(_typingSince!) > _typingPing) {
      _typingSince = now;
      widget.onTyping?.call(true);
    }
    _typingStop?.cancel();
    _typingStop = Timer(_typingIdle, _stopTyping);
  }

  void _stopTyping() {
    _typingStop?.cancel();
    _typingStop = null;
    if (_typingSince == null) return;
    _typingSince = null;
    widget.onTyping?.call(false);
  }

  void _scheduleMarkRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _markingRead) return;
      final uid = widget.myUid;
      final markRead = widget.onMarkRead;
      if (uid == null || markRead == null) return;
      if (!widget.messages.any((m) => !m.isMine(uid) && !m.isRead)) return;

      _markingRead = true;
      unawaited(markRead().whenComplete(() => _markingRead = false));
    });
  }

  void _toggleSelected(ChatMessage message) {
    setState(() {
      _selectionMode = true;
      if (!_selected.remove(message.id)) _selected.add(message.id);
    });
  }

  void _clearSelection() => setState(() {
    _selectionMode = false;
    _selected.clear();
  });

  List<ChatMessage> get _selectedMessages => [
    for (final message in widget.messages)
      if (_selected.contains(message.id)) message,
  ];

  /// Anything in the conversation can be taken out of it, yours or theirs —
  /// and only once, since a tombstone has nothing left to delete.
  bool get _canDelete {
    final chosen = _selectedMessages;
    if (widget.onDeleteMessages == null || chosen.isEmpty) return false;
    return chosen.every((m) => !m.isDeleted);
  }

  List<String> get _selectedImages => [
    for (final message in _selectedMessages)
      if (message.hasImage) message.imageUrl,
  ];

  /// What the ⋮ menu offers. The last three are only there when the screen
  /// knows how to do them.
  List<PopupMenuEntry<void>> _menuItems() => [
    _menuItem(
      key: const Key('menu-select'),
      icon: Icons.check_box_outlined,
      label: 'Seleccionar mensajes',
      onTap: () => setState(() => _selectionMode = true),
    ),
    _menuItem(
      key: const Key('menu-export'),
      icon: Icons.ios_share,
      label: 'Exportar chat',
      onTap: _exportChat,
    ),
    if (widget.onSetBlocked != null)
      _menuItem(
        key: const Key('menu-block'),
        icon: Icons.block,
        label: widget.blocked ? 'Desbloquear' : 'Bloquear',
        onTap: () => _setBlocked(blocked: !widget.blocked),
      ),
    if (widget.onClearChat != null)
      _menuItem(
        key: const Key('menu-clear'),
        icon: Icons.remove_circle_outline,
        label: 'Vaciar chat',
        onTap: _clearChat,
      ),
    if (widget.onDeleteChat != null)
      _menuItem(
        key: const Key('menu-delete'),
        icon: Icons.delete_outline,
        label: 'Eliminar chat',
        onTap: _deleteChat,
      ),
  ];

  /// A menu row. The work runs after the menu closes, so a dialog of its own
  /// has a route to sit on.
  PopupMenuItem<void> _menuItem({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      PopupMenuItem<void>(
        key: key,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: BrandColors.grey800),
            const SizedBox(width: Insets.md),
            // Flexible: a narrow menu shortens the label rather than
            // overflowing the row.
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );

  /// The conversation as plain text, on the clipboard.
  ///
  /// Copying rather than writing a file: it lands in WhatsApp, a mail, or a
  /// note without asking for storage permission anywhere.
  Future<void> _exportChat() async {
    final messages = _visibleMessages;
    if (messages.isEmpty) {
      _say('No hay mensajes para exportar.');
      return;
    }

    final uid = widget.myUid;
    final lines = <String>['Chat con ${widget.title}', ''];
    for (final message in messages) {
      final who = uid != null && message.isMine(uid) ? 'Tú' : widget.title;
      final when = message.sentAt;
      final what = message.isDeleted
          ? '[mensaje eliminado]'
          : message.hasImage && message.text.isEmpty
          ? '[foto]'
          : message.hasImage
          ? '[foto] ${message.text}'
          : message.text;
      lines.add(
        when == null ? '$who: $what' : '${DoTime.dateAndTime(when)} — $who: $what',
      );
    }

    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    _say('Chat copiado. Pégalo donde quieras guardarlo.');
  }

  /// Says, in as many words, that the other side will not receive this.
  ///
  /// The rules refuse the write anyway; catching it here means the answer is
  /// "te bloqueó" instead of a failure the person cannot act on.
  Future<bool> _refusedByBlock() async {
    if (!widget.blockedByOther) return false;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('blocked-by-other-dialog'),
        title: const Text('Te bloquearon'),
        content: Text(
          '${widget.title} te bloqueó, así que no recibirá tus mensajes en '
          'esta conversación.',
        ),
        actions: [
          TextButton(
            key: const Key('blocked-by-other-ok'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
    return true;
  }

  Future<void> _setBlocked({required bool blocked}) async {
    final set = widget.onSetBlocked;
    if (set == null) return;

    if (blocked) {
      final confirmed = await _confirm(
        key: const Key('confirm-block'),
        title: '¿Bloquear a ${widget.title}?',
        message: 'No podrás escribirle en esta conversación. La otra persona '
            'no recibe ningún aviso.',
        action: 'Bloquear',
      );
      if (!confirmed) return;
    }

    final result = await set(blocked: blocked);
    if (result case Err(:final failure)) {
      _say(failure.userMessage);
      return;
    }
    _say(blocked ? 'Bloqueaste a ${widget.title}.' : 'Desbloqueaste a ${widget.title}.');
  }

  Future<void> _clearChat() async {
    final clear = widget.onClearChat;
    if (clear == null) return;
    final confirmed = await _confirm(
      key: const Key('confirm-clear'),
      title: '¿Vaciar el chat?',
      message: 'Se borran los mensajes de tu pantalla. La otra persona sigue '
          'viendo los suyos.',
      action: 'Vaciar',
    );
    if (!confirmed) return;

    final result = await clear();
    if (result case Err(:final failure)) _say(failure.userMessage);
  }

  Future<void> _deleteChat() async {
    final delete = widget.onDeleteChat;
    if (delete == null) return;
    final confirmed = await _confirm(
      key: const Key('confirm-delete-chat'),
      title: '¿Eliminar el chat?',
      message: 'Sale de tu lista y se vacía. Vuelve si te escriben de nuevo.',
      action: 'Eliminar',
    );
    if (!confirmed) return;

    final result = await delete();
    if (result case Err(:final failure)) {
      _say(failure.userMessage);
      return;
    }
    // Nothing left to look at on this screen.
    if (mounted) await Navigator.of(context).maybePop();
  }

  /// The one question these actions all ask before doing anything.
  Future<bool> _confirm({
    required Key key,
    required String title,
    required String message,
    required String action,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            key: key,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  String get _query => _search.text.trim().toLowerCase();

  /// What the list shows: the conversation minus whatever this person emptied
  /// out of it, and minus what the search leaves behind.
  List<ChatMessage> get _visibleMessages {
    final query = _query;
    final cleared = ChatThreadPrefs(clearedAt: widget.hiddenBefore);
    return [
      for (final message in widget.messages)
        if (!cleared.hides(message) &&
            (query.isEmpty || message.text.toLowerCase().contains(query)))
          message,
    ];
  }

  void _startSearch() => setState(() => _searching = true);

  void _stopSearch() => setState(() {
    _searching = false;
    _search.clear();
  });

  /// Why the two of them cannot call each other right now, or null when they
  /// can.
  ///
  /// A call is the same conversation by another route: blocking somebody has
  /// to stop their phone ringing too, and a conversation that is over stays
  /// over. The server refuses both regardless — this is so the buttons say
  /// why rather than asking for the microphone and failing.
  String? get _cannotCall {
    if (widget.blocked) return 'Desbloquéalo para poder llamar.';
    if (widget.blockedByOther) return 'No puedes llamar a esta persona.';
    if (!widget.canWrite) return widget.closedNotice;
    return null;
  }

  /// Places the in-app call where there is one; otherwise hands the number to
  /// the phone's dialer.
  Future<void> _call() async {
    final refusal = _cannotCall;
    if (refusal != null) {
      _say(refusal);
      return;
    }
    final onCall = widget.onCall;
    if (onCall != null) {
      onCall();
      return;
    }
    final number = widget.phoneNumber;
    if (number.isEmpty) {
      _say('Todavía no tenemos su número de teléfono.');
      return;
    }
    final opened = await launchUrl(Uri(scheme: 'tel', path: number));
    if (!opened) _say('No se pudo abrir el teléfono.');
  }

  /// Rings the other person's app with video, where the chat has a service to
  /// call through; otherwise says why it cannot rather than doing nothing.
  void _videoCall() {
    final refusal = _cannotCall;
    if (refusal != null) {
      _say(refusal);
      return;
    }
    final onVideoCall = widget.onVideoCall;
    if (onVideoCall != null) {
      onVideoCall();
      return;
    }
    _say('La videollamada está disponible durante un servicio.');
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copySelected() async {
    final text = [
      for (final message in _selectedMessages)
        if (message.text.isNotEmpty) message.text,
    ].join('\n');

    _clearSelection();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copiado')));
  }

  /// Asks first: this takes the message off the other person's screen too.
  Future<void> _deleteSelected() async {
    final delete = widget.onDeleteMessages;
    final ids = _selectedMessages.map((m) => m.id).toList();
    if (delete == null || ids.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          ids.length == 1
              ? '¿Eliminar el mensaje?'
              : '¿Eliminar ${ids.length} mensajes?',
        ),
        content: const Text(
          'Se eliminan para los dos. En su lugar queda el aviso de que se '
          'eliminó un mensaje.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _clearSelection();
    final result = await delete(ids);
    if (!mounted) return;
    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.userMessage)));
    }
  }

  Future<void> _downloadSelected() async {
    final download = widget.onDownloadImages;
    final urls = _selectedImages;
    if (download == null || urls.isEmpty) return;
    _clearSelection();
    await download(urls);
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;
    if (await _refusedByBlock()) return;

    setState(() => _sending = true);
    _controller.clear();
    // A sent message is the end of typing it.
    _stopTyping();

    // Lets an optimistic bubble reconcile with the server echo, and stops a
    // retry on bad signal from duplicating the message.
    final clientMsgId =
        '${widget.myUid ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}';
    final result = await widget.onSend(trimmed, clientMsgId);

    if (!mounted) return;
    setState(() => _sending = false);

    result.fold(
      (_) => _scrollToBottom(),
      (failure) =>
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(failure.userMessage))),
    );
  }

  /// Camera or gallery, then upload and send. The bubble appears when the
  /// photo is in the bucket, so nothing half-sent shows in the conversation.
  Future<void> _attach() async {
    final picker = widget.photoPicker;
    final send = widget.onSendImage;
    if (picker == null || send == null || _sending) return;

    if (await _refusedByBlock() || !mounted) return;

    final source = await askPhotoSource(context);
    if (source == null || !mounted) return;
    final photo = await picker(source);
    if (photo == null || !mounted) return;

    // The ceiling storage.rules puts on a chat photo, said here rather than as
    // a refused upload after the wait.
    if (photo.bytes.lengthInBytes > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('La foto pesa ${photo.sizeLabel}. Máximo 5 MB.'),
        ),
      );
      return;
    }

    setState(() => _sending = true);
    final result = await send(
      photo,
      '${widget.myUid ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (!mounted) return;
    setState(() => _sending = false);

    result.fold(
      (_) => _scrollToBottom(),
      (failure) =>
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(failure.userMessage))),
    );
  }

  /// Back to the newest message after sending one.
  ///
  /// The list is reversed, so the newest end is offset zero — not the maximum
  /// extent, which is now the oldest message in the history.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.minScrollExtent,
        duration: Motion.normal,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.myUid;
    final messages = _visibleMessages;
    final subtitle = widget.subtitle;

    return PopScope(
      // Back leaves the selection, then the search, before it leaves the
      // conversation.
      canPop: !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _clearSelection();
        } else {
          _stopSearch();
        }
      },
      child: Scaffold(
        backgroundColor: BrandColors.offWhite,
        appBar: _searching
            ? AppBar(
                titleSpacing: 0,
                leading: IconButton(
                  key: const Key('chat-search-close'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _stopSearch,
                ),
                title: TextField(
                  key: const Key('chat-search-field'),
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Buscar en el chat…',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                actions: [
                  if (_search.text.isNotEmpty)
                    IconButton(
                      key: const Key('chat-search-clear'),
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_search.clear),
                    ),
                ],
              )
            : AppBar(
                // Beside the face, as a conversation reads everywhere else,
                // rather than centred over it.
                centerTitle: false,
                titleSpacing: 0,
                title: Row(
                  children: [
                    DriverAvatar(
                      key: const Key('chat-avatar'),
                      name: widget.title,
                      photoUrl: widget.photoUrl,
                      size: 36,
                    ),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (subtitle != null && subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: BrandColors.grey600),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                actions: [
                  // Compact, so four actions and a name still fit a phone.
                  IconButton(
                    key: const Key('chat-video-call'),
                    tooltip: _cannotCall ?? 'Videollamada',
                    visualDensity: VisualDensity.compact,
                    // Still tappable while it is off: a grey button that does
                    // nothing leaves somebody guessing, and the tap answers.
                    color: _cannotCall == null ? null : BrandColors.grey400,
                    icon: const Icon(Icons.videocam_outlined),
                    onPressed: _videoCall,
                  ),
                  IconButton(
                    key: const Key('chat-call'),
                    tooltip: _cannotCall ?? 'Llamar',
                    visualDensity: VisualDensity.compact,
                    color: _cannotCall == null ? null : BrandColors.grey400,
                    icon: const Icon(Icons.call_outlined),
                    onPressed: _call,
                  ),
                  IconButton(
                    key: const Key('chat-search'),
                    tooltip: 'Buscar en el chat',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.search),
                    onPressed: _startSearch,
                  ),
                  ...widget.actions,
                  PopupMenuButton<void>(
                    key: const Key('chat-menu'),
                    tooltip: 'Más opciones',
                    icon: const Icon(Icons.more_vert),
                    // Drops below the header rather than over it: the name of
                    // whoever you are talking to stays readable while you
                    // choose. The offset clears the header's edge, so the menu
                    // reads as its own card instead of hanging off the bar.
                    position: PopupMenuPosition.under,
                    offset: const Offset(0, Insets.sm),
                    itemBuilder: (context) => _menuItems(),
                  ),
                ],
              ),
        body: Column(
          children: [
            if (widget.banner != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.md,
                  Insets.lg,
                  0,
                ),
                child: widget.banner,
              ),
            Expanded(
              child: messages.isEmpty
                  ? EmptyState(
                      title: _query.isEmpty ? 'Sin mensajes' : 'Sin resultados',
                      message: _query.isEmpty
                          ? widget.emptyMessage
                          : 'Ningún mensaje de esta conversación dice '
                                '"${_search.text.trim()}".',
                      icon: _query.isEmpty
                          ? Icons.chat_bubble_outline
                          : Icons.search_off,
                    )
                  // Built from the bottom up: a conversation opens on the
                  // last thing said, which is what somebody came to read, and
                  // stays put when a message arrives while they scroll back
                  // through the history.
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.all(Insets.lg),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[messages.length - 1 - index];
                        return _SelectableMessage(
                          selecting: _selecting,
                          selected: _selected.contains(message.id),
                          onLongPress: () => _toggleSelected(message),
                          onTap: _selecting
                              ? () => _toggleSelected(message)
                              : null,
                          child: _Bubble(
                            message: message,
                            isMine: uid != null && message.isMine(uid),
                          ),
                        );
                      },
                    ),
            ),
            if (_selecting)
              _SelectionBar(
                count: _selected.length,
                canCopy: _selected.isNotEmpty,
                canDelete: _canDelete,
                canDownload: _selectedImages.isNotEmpty,
                onClose: _clearSelection,
                onCopy: _copySelected,
                onDelete: _deleteSelected,
                onDownload: _downloadSelected,
              )
            else if (widget.blocked)
              _BlockedNotice(
                name: widget.title,
                onUnblock: () => _setBlocked(blocked: false),
              )
            else if (widget.canWrite) ...[
              if (widget.otherTyping) const _TypingLine(),
              _Composer(
                controller: _controller,
                sending: _sending,
                onSend: () => _send(_controller.text),
                onAttach:
                    widget.photoPicker == null || widget.onSendImage == null
                    ? null
                    : _attach,
                onChanged: widget.onTyping == null ? null : _onComposerChanged,
              ),
            ] else
              _ChatClosedNotice(text: widget.closedNotice),
          ],
        ),
      ),
    );
  }
}

/// One message, and the checkbox that appears beside it while messages are
/// being picked out.
///
/// The box sits on the right of every row, whoever sent the message: a column
/// of boxes down one edge is easier to run a thumb along than boxes that
/// follow the bubbles from side to side.
class _SelectableMessage extends StatelessWidget {
  const _SelectableMessage({
    required this.selecting,
    required this.selected,
    required this.onLongPress,
    required this.onTap,
    required this.child,
  });

  final bool selecting;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      onTap: onTap,
      child: ColoredBox(
        color: selected ? BrandColors.redTint : Colors.transparent,
        child: Row(
          children: [
            // While picking, a tap belongs to the selection — otherwise
            // tapping a photo would open it full-screen instead of ticking it.
            Expanded(
              child: AbsorbPointer(absorbing: selecting, child: child),
            ),
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(
                  left: Insets.sm,
                  bottom: Insets.sm,
                ),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  key: Key(selected ? 'selected-mark' : 'unselected-mark'),
                  size: 22,
                  color: selected ? BrandColors.red : BrandColors.grey400,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the message box becomes while messages are picked out: how many, and
/// the three things that can be done with them.
///
/// At the bottom, in the box's place, rather than up in the header — the hand
/// that just long-pressed a bubble is already down there, and the count sits
/// beside the buttons it applies to.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.canCopy,
    required this.canDelete,
    required this.canDownload,
    required this.onClose,
    required this.onCopy,
    required this.onDelete,
    required this.onDownload,
  });

  final int count;
  final bool canCopy;
  final bool canDelete;
  final bool canDownload;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: BrandColors.white,
        border: Border(top: BorderSide(color: BrandColors.grey100)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          // The same breathing room the message box has, so the bottom of the
          // screen keeps its height when the bar takes the box's place.
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs,
            vertical: Insets.md,
          ),
          child: Row(
            children: [
              IconButton(
                key: const Key('selection-close'),
                tooltip: 'Salir de la selección',
                onPressed: onClose,
                icon: const Icon(Icons.close, color: BrandColors.grey800),
              ),
              Expanded(
                child: Text(
                  count == 1 ? '1 seleccionado' : '$count seleccionados',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const Key('selection-copy'),
                tooltip: 'Copiar',
                onPressed: canCopy ? onCopy : null,
                icon: const Icon(Icons.copy_outlined),
                color: BrandColors.grey800,
              ),
              IconButton(
                key: const Key('selection-delete'),
                tooltip: 'Eliminar para todos',
                // Only your own messages, and only while they still say
                // something.
                onPressed: canDelete ? onDelete : null,
                icon: const Icon(Icons.delete_outline),
                color: BrandColors.danger,
              ),
              IconButton(
                key: const Key('selection-download'),
                tooltip: 'Guardar foto',
                // Nothing to save unless a photo is among the chosen.
                onPressed: canDownload ? onDownload : null,
                // Reads as "keep this on my phone" rather than the thin
                // browser-download arrow.
                icon: const Icon(Icons.save_alt_rounded),
                color: BrandColors.grey800,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.76,
        ),
        margin: const EdgeInsets.only(bottom: Insets.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.md,
        ),
        decoration: BoxDecoration(
          color: isMine ? BrandColors.red : BrandColors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(Corners.md),
            topRight: const Radius.circular(Corners.md),
            bottomLeft: Radius.circular(isMine ? Corners.md : Corners.xs),
            bottomRight: Radius.circular(isMine ? Corners.xs : Corners.md),
          ),
          boxShadow: isMine ? null : Shadows.card,
        ),
        child: Column(
          crossAxisAlignment: isMine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (message.isDeleted)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.block,
                    size: 14,
                    color: isMine ? Colors.white70 : BrandColors.grey400,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    'Se eliminó este mensaje',
                    style: text.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: isMine ? Colors.white70 : BrandColors.grey600,
                    ),
                  ),
                ],
              ),
            if (message.hasImage) ...[
              _ChatImage(url: message.imageUrl),
              if (message.text.isNotEmpty) const SizedBox(height: Insets.sm),
            ],
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: text.bodyMedium?.copyWith(
                  color: isMine ? BrandColors.white : BrandColors.ink,
                ),
              ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.isPending
                      ? 'Enviando…'
                      : DoTime.time(message.sentAt ?? DateTime.now().toUtc()),
                  style: text.bodySmall?.copyWith(
                    fontSize: 10,
                    color: isMine ? Colors.white70 : BrandColors.grey400,
                  ),
                ),
                // Only on your own messages, and not on a retracted one.
                if (isMine && !message.isDeleted) ...[
                  const SizedBox(width: Insets.xs),
                  _DeliveryTick(message: message),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a message of yours has got to: waiting to leave the phone, on the
/// server, or seen by the other side.
///
/// One grey-white check means the server has it. Two blue checks mean it was
/// read — the same shorthand every messaging app has taught people to expect,
/// which is why it needs no legend.
class _DeliveryTick extends StatelessWidget {
  const _DeliveryTick({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isPending) {
      return const Icon(
        Icons.schedule,
        key: Key('tick-pending'),
        size: 13,
        color: Colors.white70,
      );
    }
    if (!message.isRead) {
      return const Icon(
        Icons.check,
        key: Key('tick-sent'),
        size: 14,
        color: Colors.white70,
      );
    }
    return const Icon(
      Icons.done_all,
      key: Key('tick-read'),
      size: 14,
      color: BrandColors.readTick,
    );
  }
}

/// "Escribiendo…", right above the box — where the words are about to land,
/// rather than up beside the name where a glance does not go.
class _TypingLine extends StatelessWidget {
  const _TypingLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
      child: Text(
        'Escribiendo…',
        key: const Key('typing-indicator'),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: BrandColors.success, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.onAttach,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: BrandColors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.md,
            Insets.lg,
            Insets.md,
          ),
          child: Row(
            children: [
              if (onAttach != null)
                IconButton(
                  key: const Key('chat-attach'),
                  tooltip: 'Enviar una foto',
                  onPressed: sending ? null : onAttach,
                  icon: const Icon(
                    Icons.attach_file,
                    color: BrandColors.grey600,
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 1000,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: onChanged,
                  onSubmitted: (_) => onSend(),
                  decoration: const InputDecoration(
                    hintText: 'Escribe un mensaje…',
                    counterText: '',
                    fillColor: BrandColors.offWhite,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: Insets.lg,
                      vertical: Insets.md,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              IconButton.filled(
                key: const Key('chat-send'),
                onPressed: sending ? null : onSend,
                style: IconButton.styleFrom(
                  backgroundColor: BrandColors.red,
                  minimumSize: const Size(48, 48),
                ),
                icon: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: BrandColors.white,
                        ),
                      )
                    : const Icon(Icons.send, color: BrandColors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo in a bubble, opening full-screen on a tap.
///
/// Two sources, as everywhere else that shows an uploaded image: a real
/// download URL in production, and a data URI from the in-memory test
/// backend, which has no bucket to upload to.
class _ChatImage extends StatelessWidget {
  const _ChatImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => _ImageViewer(url: url),
        ),
      ),
      child: ClipRRect(
        borderRadius: Corners.brSm,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: chatImage(url, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(child: chatImage(url, fit: BoxFit.contain)),
            ),
          ),
          SafeArea(
            child: IconButton(
              tooltip: 'Cerrar',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: BrandColors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hands the chosen photos to the platform.
///
/// Opening rather than writing to the gallery: a browser downloads it, a phone
/// shows it in the viewer where saving is one tap, and neither needs a
/// permission prompt in the middle of a conversation.
Future<void> openChatImages(List<String> urls) async {
  for (final url in urls) {
    final uri = Uri.tryParse(url);
    if (uri == null) continue;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (error) {
      debugPrint('Chat photo not opened: $error');
    }
  }
}

/// Shown in place of a photo that will not load or decode.
const _brokenImage = Padding(
  padding: EdgeInsets.all(Insets.lg),
  child: Icon(Icons.broken_image_outlined, color: BrandColors.grey400),
);

/// Renders a chat photo from a download URL or a test backend's data URI.
Widget chatImage(String url, {BoxFit fit = BoxFit.cover}) {
  Widget broken(BuildContext _, Object _, StackTrace? _) => _brokenImage;

  // The test backend has no bucket, so its photos travel as data URIs.
  if (url.startsWith('data:')) {
    final bytes = Uri.tryParse(url)?.data?.contentAsBytes();
    if (bytes == null) return _brokenImage;
    return Image.memory(bytes, fit: fit, errorBuilder: broken);
  }
  return Image.network(
    url,
    fit: fit,
    // The web renderer decodes images itself, which needs CORS headers the
    // bucket does not send by default; an <img> element needs none.
    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
    errorBuilder: broken,
  );
}

/// What the message box becomes for somebody you blocked: the history stays
/// readable, and one tap undoes it.
class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice({required this.name, required this.onUnblock});

  final String name;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('chat-blocked-notice'),
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.all(Insets.lg),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Bloqueaste a $name.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: BrandColors.grey600),
            ),
            TextButton(
              key: const Key('chat-unblock'),
              onPressed: onUnblock,
              child: const Text('Desbloquear'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatClosedNotice extends StatelessWidget {
  const _ChatClosedNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.all(Insets.lg),
      child: SafeArea(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: BrandColors.grey600),
        ),
      ),
    );
  }
}
