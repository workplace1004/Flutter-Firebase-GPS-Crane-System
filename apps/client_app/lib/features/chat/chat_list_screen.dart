import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The customer's recent services, newest first, for the older conversations.
///
/// One page only: a conversation is worth reopening for a day or two, not a
/// year. Re-read whenever the service in flight changes, so a finished tow
/// moves down into this list without a manual refresh.
final recentClientServicesProvider = FutureProvider<List<Service>>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  ref.watch(activeClientServiceProvider.select((s) => s.value?.id));

  final result = await ref
      .read(serviceRepositoryProvider)
      .fetchHistory(userId: uid, role: UserRole.client);
  // Rethrown so the screen renders the Failure's es-DO message.
  if (result case Err(:final failure)) throw failure;
  return result.valueOrNull?.items ?? const [];
});

/// What the Chat tab's count adds up to: messages the customer has not read,
/// on the tow in progress and in every open conversation with a grúa.
///
/// A request still waiting for an answer does not count. The customer is the
/// one waiting, and a number that never goes down is not news.
final clientChatAttentionProvider = Provider<int>((ref) {
  final now = clock.now().toUtc();
  var count = 0;

  final active = ref.watch(activeClientServiceProvider).value;
  if (active != null) count += ref.watch(unreadMessageCountProvider(active.id));

  final requests = ref.watch(clientChatRequestsProvider).value ?? const [];
  for (final request in requests) {
    if (request.phaseAt(now) != ChatRequestPhase.open) continue;
    count += ref.watch(unreadChatRequestMessageCountProvider(request.id));
  }
  return count;
});

/// The Chat tab.
///
/// Three kinds of conversation, in the order they matter: the chofer bringing
/// the grúa right now, the ones opened from a truck on the map before any job,
/// and the finished services, kept read-only because "what did he say about
/// the gate" is worth being able to look up.
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeClientServiceProvider).value;
    final recent = ref.watch(recentClientServicesProvider);
    final now = clock.now().toUtc();
    // Conversations this customer deleted stay off the list until somebody
    // writes in them again, and a blocked chofer's do not come back at all.
    final blocked = ref.watch(blockedUsersProvider).value ?? const <String>{};
    final requests = [
      for (final request
          in ref.watch(clientChatRequestsProvider).value ??
              const <ChatRequest>[])
        if (request.phaseAt(now) != ChatRequestPhase.over &&
            !blocked.contains(request.driverId) &&
            !ref.watch(chatThreadHiddenProvider(requestThreadKey(request.id))))
          request,
    ];
    final showActive = active != null &&
        active.canChat &&
        !ref.watch(chatThreadHiddenProvider(jobThreadKey(active.id)));

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mensajes'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(recentClientServicesProvider.future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.lg,
            Insets.xxl,
          ),
          children: [
            const FieldLabel('Servicio en curso'),
            const SizedBox(height: Insets.sm),
            if (showActive)
              _ActiveConversation(service: active)
            else
              const _NoConversationCard(),
            if (requests.isNotEmpty) ...[
              const SizedBox(height: Insets.xl),
              const FieldLabel('Grúas del mapa'),
              const SizedBox(height: Insets.sm),
              for (final request in requests)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: _RequestConversation(request: request),
                ),
            ],
            const SizedBox(height: Insets.xl),
            const FieldLabel('Servicios anteriores'),
            const SizedBox(height: Insets.sm),
            ...recent.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(Insets.xl),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ],
              error: (error, _) => [
                InlineNotice(
                  message: error is Failure
                      ? error.userMessage
                      : 'No pudimos cargar tus servicios anteriores.',
                  tone: NoticeTone.error,
                  icon: Icons.cloud_off_outlined,
                  actionLabel: 'Reintentar',
                  onAction: () => ref.invalidate(recentClientServicesProvider),
                ),
              ],
              data: (services) {
                final past = [
                  for (final service in services)
                    if (service.id != active?.id &&
                        !ref.watch(
                          chatThreadHiddenProvider(jobThreadKey(service.id)),
                        ))
                      service,
                ];
                if (past.isEmpty) {
                  return [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                      child: Text(
                        'Todavía no tienes servicios anteriores.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: BrandColors.grey600),
                      ),
                    ),
                  ];
                }
                return [
                  for (final service in past)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.sm),
                      child: _PastConversation(service: service),
                    ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The chofer on the way: who, the last thing said, and what is unread.
class _ActiveConversation extends ConsumerWidget {
  const _ActiveConversation({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final uid = ref.watch(currentUserIdProvider);
    final messages =
        ref.watch(serviceMessagesProvider(service.id)).value ?? const [];
    final unread = ref.watch(unreadMessageCountProvider(service.id));
    final last = messages.isEmpty ? null : messages.last;

    return FloatingCard(
      key: const Key('active-conversation'),
      onTap: () => context.push(Routes.chatFor(service.id)),
      child: _ConversationRow(
        avatar: _Face(
          name: service.driverName,
          photoUrl: service.driverPhotoUrl,
          highlighted: true,
        ),
        title: service.driverName.isEmpty ? 'Chofer' : service.driverName,
        subtitle: last == null
            ? 'Escríbele al chofer si necesitas darle alguna indicación.'
            : _preview(last, uid),
        unread: unread,
        text: text,
      ),
    );
  }
}

/// A grúa asked from the map: waiting for the chofer's answer, or talking.
class _RequestConversation extends ConsumerWidget {
  const _RequestConversation({required this.request});

  final ChatRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final waiting =
        request.phaseAt(clock.now().toUtc()) == ChatRequestPhase.waiting;
    final uid = ref.watch(currentUserIdProvider);
    final messages =
        ref.watch(chatRequestMessagesProvider(request.id)).value ?? const [];
    final unread = ref.watch(unreadChatRequestMessageCountProvider(request.id));
    final last = messages.isEmpty ? null : messages.last;

    // The chofer is nobody until they answer: no name to show, and none to
    // learn from this screen either.
    final title = waiting
        ? 'Grúa cercana'
        : request.driverName.isEmpty
        ? 'Chofer'
        : request.driverName;

    return FloatingCard(
      key: Key('chat-request-${request.id}'),
      onTap: () => context.push(Routes.chatRequestFor(request.id)),
      child: _ConversationRow(
        avatar: waiting
            // Nobody has answered, so there is nobody to show.
            ? const _Face(name: '', waiting: true)
            : _Face(name: title, photoUrl: request.driverPhotoUrl),
        title: title,
        subtitle: waiting
            ? 'Esperando que el chofer conteste…'
            : last == null
            ? 'Conversación abierta'
            : _preview(last, uid),
        unread: unread,
        text: text,
      ),
    );
  }
}

/// A finished service's conversation, opened read-only.
class _PastConversation extends StatelessWidget {
  const _PastConversation({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final createdAt = service.createdAt;

    return FloatingCard(
      onTap: () => context.push(Routes.chatFor(service.id)),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Row(
        children: [
          _Face(name: service.driverName, photoUrl: service.driverPhotoUrl),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.driverName.isEmpty ? 'Chofer' : service.driverName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                Text(
                  [
                    service.code,
                    if (createdAt != null) DoTime.relative(createdAt),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          StatusChip(service.status, compact: true),
        ],
      ),
    );
  }
}

/// The shape every conversation tile shares.
class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.unread,
    required this.text,
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final int unread;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        avatar,
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: unread > 0 ? BrandColors.ink : BrandColors.grey600,
                  fontWeight: unread > 0 ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        if (unread > 0)
          Badge.count(
            count: unread,
            backgroundColor: BrandColors.red,
            textColor: BrandColors.white,
          )
        else
          const Icon(Icons.chevron_right, color: BrandColors.grey400),
      ],
    );
  }
}

/// The last thing said, as one line. A photo with no words says so.
String _preview(ChatMessage last, String? uid) {
  final mine = uid != null && last.isMine(uid) ? 'Tú: ' : '';
  final body = last.text.isEmpty && last.hasImage ? 'Foto' : last.text;
  return '$mine$body';
}

class _NoConversationCard extends StatelessWidget {
  const _NoConversationCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.xl,
      ),
      child: Column(
        children: [
          const Icon(
            Icons.chat_bubble_outline,
            size: 30,
            color: BrandColors.grey400,
          ),
          const SizedBox(height: Insets.md),
          Text('Sin conversación activa', style: text.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(
            'El chat se abre cuando un chofer acepta tu servicio. También '
            'puedes escribirle a una grúa del mapa.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

/// The chofer's face: their photo when there is one, their initial when not,
/// and a truck while nobody has answered yet.
class _Face extends StatelessWidget {
  const _Face({
    required this.name,
    this.photoUrl = '',
    this.highlighted = false,
    this.waiting = false,
  });

  final String name;
  final String photoUrl;
  final bool highlighted;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    // A photo says more than a letter, and the shared avatar already handles
    // a missing one, a broken one, and the test backend's data URIs.
    if (!waiting && photoUrl.isNotEmpty) {
      return DriverAvatar(name: name, photoUrl: photoUrl, size: 44);
    }

    final trimmed = name.trim();
    final (background, foreground) = switch ((highlighted, waiting)) {
      (true, _) => (BrandColors.redTint, BrandColors.red),
      (_, true) => (BrandColors.warningTint, BrandColors.warning),
      _ => (BrandColors.grey100, BrandColors.grey600),
    };

    return CircleAvatar(
      radius: 22,
      backgroundColor: background,
      child: waiting || trimmed.isEmpty
          ? Icon(
              waiting ? Icons.local_shipping : Icons.person_outline,
              size: 20,
              color: foreground,
            )
          : Text(
              trimmed[0].toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: foreground),
            ),
    );
  }
}
