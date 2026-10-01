import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../auth/app_presence.dart';
import '../notifications/notification_widgets.dart';
import '../rating/rate_client.dart';
import 'driver_map.dart';
import 'offer_card.dart';

/// The Inicio tab: the map, edge to edge, with the chofer's controls over it.
///
/// Everything else a chofer looks at — the open orders, the conversation, the
/// account — has its own tab, so this screen stays one decision deep: am I
/// taking work, and is there a request for me right now. An offer takes the
/// place of the online card, because while it is up nothing else matters.
///
/// Going online is a checklist, not a boolean. A chofer who flips the switch
/// and then silently misses every offer because notifications are off is worse
/// than one who was told up front what is missing.
class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  /// How much of the map's bottom the card over it covers. Measured after
  /// layout, so the camera frames the job in the part the chofer can see
  /// whether the card is the short online switch or a full offer.
  var _coveredBottom = 0.0;

  void _onCardHeight(double height) {
    if (!mounted || height == _coveredBottom) return;
    setState(() => _coveredBottom = height);
  }

  @override
  Widget build(BuildContext context) {
    final driverAsync = ref.watch(currentDriverProvider);
    final driver = driverAsync.value;

    // Three different situations used to collapse into one spinner that never
    // stopped: the record still loading, the read being refused, and no chofer
    // record existing for this account at all. Only the first is temporary, so
    // only the first gets a spinner — the other two now say what is wrong and
    // leave a way out, because a chofer stuck on a spinner has no way to tell
    // whether to wait, call the office, or sign in with the other account.
    if (driver == null) {
      if (driverAsync.isLoading) return const Scaffold(body: BrandLoader());
      return _UnavailableScreen(error: driverAsync.error);
    }

    // The job the server is offering this chofer right now, if any. The map
    // frames it and its card replaces the online switch.
    final offer = ref.watch(openOfferProvider);
    final coveredTop =
        MediaQuery.paddingOf(context).top + Insets.md + _Header.height;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned.fill(
              child: DriverMap(
                offer: offer,
                padding: EdgeInsets.only(
                  top: coveredTop,
                  bottom: _coveredBottom,
                ),
              ),
            ),
            // Positioned, like everything else here: a Stack sizes itself to
            // its unpositioned children, and the header alone would shrink
            // the whole screen — map included — to the header's height.
            // Positioned, like everything else here: a Stack sizes itself to
            // its unpositioned children, and the header alone would shrink
            // the whole screen — map included — to the header's height.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Header(driver: driver),
                    const _BalancePill(),
                    const SizedBox(height: Insets.sm),
                    // The mark over the map, as on the customer's home. It
                    // lets touches through, so the map still pans under it.
                    const IgnorePointer(child: GruaLogo(size: 120)),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _MeasureHeight(
                onHeight: _onCardHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    0,
                    Insets.lg,
                    Insets.lg,
                  ),
                  // A tall offer on a short phone scrolls rather than sliding
                  // its buttons under the header.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(
                        0,
                        constraints.maxHeight - coveredTop - Insets.huge,
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: offer == null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const _OfferStreamNotice(),
                                // The customer of the job just finished,
                                // while their rating is still owed.
                                const PendingClientRating(),
                                _OnlineCard(driver: driver),
                              ],
                            )
                          : OfferCard(
                              key: ValueKey(offer.serviceId),
                              offer: offer,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chofer's photo, name, truck and today's take, floating over the map.
/// The photo carries the online dot, so the header says at a glance whether
/// dispatch can see them.
class _Header extends ConsumerWidget {
  const _Header({required this.driver});

  final Driver driver;

  /// Fixed, so the map knows how much of its top the header covers.
  static const double height = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final today = ref.watch(driverEarningsProvider).value?.todayNetCents ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
      child: Row(
        children: [
          Expanded(child: _headerCard(context, text, today)),
          const SizedBox(width: Insets.md),
          const NotificationBell(),
        ],
      ),
    );
  }

  Widget _headerCard(BuildContext context, TextTheme text, int today) {
    return SizedBox(
      height: height,
      child: FloatingCard(
        padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.xs, 0),
        borderRadius: Corners.brMd,
        child: Row(
          children: [
            DriverAvatar.of(driver, size: 48),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    driver.shortName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium,
                  ),
                  Text(
                    // Without a grúa the type is "Desconocido", which reads
                    // as something wrong with the chofer, not the truck.
                    driver.assignedTruckId == null
                        ? 'Sin grúa asignada'
                        : [
                            if (driver.assignedTruckPlate.isNotEmpty)
                              driver.assignedTruckPlate,
                            driver.truckType.label,
                          ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ),
            ),
            _TodayPill(
              cents: today,
              onTap: () => context.push(Routes.earnings),
            ),
          ],
        ),
      ),
    );
  }
}

/// Today's net, one tap from the full breakdown.
/// What Titan and the chofer owe each other, as a chip under the header and
/// one tap from the cortes. Nothing at all while there is no balance.
class _BalancePill extends ConsumerWidget {
  const _BalancePill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final total = ref.watch(myDriverBalanceProvider)?.totalCents ?? 0;
    if (total == 0) return const SizedBox.shrink();
    final owed = total > 0;
    final color = owed ? BrandColors.success : BrandColors.danger;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: BrandColors.white,
          elevation: 2,
          borderRadius: Corners.brMd,
          child: InkWell(
            key: const Key('home-balance'),
            onTap: () => context.push(Routes.settlements),
            borderRadius: Corners.brMd,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.account_balance_wallet_outlined, size: 18, color: color),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: Text(
                      owed
                          ? 'Titan te debe ${total.formatDOP}'
                          : 'Debes ${(-total).formatDOP} a Titan',
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(color: color),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: BrandColors.grey400),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TodayPill extends StatelessWidget {
  const _TodayPill({required this.cents, required this.onTap});

  final int cents;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Tooltip(
      message: 'Mis ganancias',
      child: InkWell(
        key: const Key('today-earnings'),
        onTap: onTap,
        borderRadius: Corners.brSm,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'HOY',
                style: text.labelSmall?.copyWith(color: BrandColors.grey600),
              ),
              Text(
                cents.formatDOP,
                style: text.titleSmall?.copyWith(color: BrandColors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The online switch plus the reason it is unavailable, if it is.
/// Says so when the offers listener is broken.
///
/// "En línea · Estás recibiendo pedidos" over a stream that is failing is the
/// worst thing this app can tell somebody: they sit there believing the night
/// is quiet while dispatch offers their jobs to other people. A refused or
/// unindexed query reads as "no offers" and looks exactly like silence, so it
/// has to be said out loud.
class _OfferStreamNotice extends ConsumerWidget {
  const _OfferStreamNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(incomingOfferProvider);
    if (!offers.hasError) return const SizedBox.shrink();

    final error = offers.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: InlineNotice(
        message: error is Failure
            ? 'No estamos recibiendo pedidos: ${error.userMessage}'
            : 'No estamos recibiendo pedidos. Revisa tu conexión.',
        icon: Icons.notifications_off_outlined,
        tone: NoticeTone.error,
        actionLabel: 'Reintentar',
        onAction: () => ref.invalidate(incomingOfferProvider),
      ),
    );
  }
}

/// Only what the chofer has to know about, over the map — nothing otherwise.
///
/// Online is the normal state now that opening the app is being at work, so
/// "En línea · Estás recibiendo pedidos" said nothing and covered the bottom of
/// the map to say it. This shows up only when something is wrong or owed: an
/// account that cannot work, no grúa, a refusal from the server, cash to hand
/// in.
class _OnlineCard extends ConsumerWidget {
  const _OnlineCard({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto = ref.watch(autoOnlineProvider);

    // Everything that must be true before dispatch can reach this chofer.
    final blockers = <String>[
      if (!driver.status.canWork) 'Tu cuenta no está activa',
      if (driver.assignedTruckId == null) 'No tienes una grúa asignada',
    ];

    final notices = <Widget>[
      if (blockers.isNotEmpty)
        InlineNotice(
          key: const Key('online-blocked'),
          message: 'No recibirás pedidos: ${blockers.join(' · ')}',
          tone: NoticeTone.error,
        )
      else if (auto.failure != null && !driver.isOnline)
        // The server's reason. The app keeps trying on its own, so there is
        // nothing to press.
        InlineNotice(
          key: const Key('online-blocked'),
          message: 'No recibirás pedidos: ${auto.failure!.userMessage}',
          tone: NoticeTone.error,
        ),
      if (driver.cashOwedCents > 0)
        InlineNotice(
          message: 'Efectivo por entregar: ${driver.cashOwedCents.formatDOP}',
          icon: Icons.payments_outlined,
        ),
    ];

    if (notices.isEmpty) return const SizedBox.shrink();

    return FloatingCard(
      child: Column(
        children: [
          for (var i = 0; i < notices.length; i++) ...[
            if (i > 0) const SizedBox(height: Insets.md),
            notices[i],
          ],
        ],
      ),
    );
  }
}

/// Reports its child's height after each layout that changes it.
class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // After the frame: layout is no place to rebuild the map above it.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}

/// Shown when the chofer record cannot be read, or is not there at all.
///
/// The two cases look identical from inside the app — an empty stream either
/// way — but need opposite reactions from the person holding the phone, so they
/// are named separately. Both offer a way out: a chofer who signed in with the
/// wrong account, or whose account the office has not finished creating, would
/// otherwise be stranded on this screen with no gesture available.
class _UnavailableScreen extends ConsumerWidget {
  const _UnavailableScreen({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `permission-denied` here is almost never the chofer's fault: the rules
    // require an App Check token alongside the sign-in, so a device that could
    // not attest is refused exactly like an impostor would be.
    final failure = error;
    final denied =
        failure is Failure && failure.code == FailureCode.permissionDenied;

    final (title, message) = switch ((error, denied)) {
      (null, _) => (
        'No encontramos tu perfil de chofer',
        'Iniciaste sesión, pero esta cuenta todavía no tiene un chofer '
            'asignado. La oficina tiene que crearla antes de que puedas '
            'trabajar. Si tienes otra cuenta, cierra sesión y entra con esa.',
      ),
      (_, true) => (
        'Sin permiso para leer tu perfil',
        'El servidor rechazó la lectura. Suele ser la verificación de la app '
            'en este dispositivo. Comunícate con la oficina.',
      ),
      _ => (
        'No pudimos cargar tu perfil',
        'Revisa tus datos móviles o el WiFi e intenta de nuevo.',
      ),
    };

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: EmptyState(
                title: title,
                message: message,
                icon: Icons.person_off_outlined,
                tone: EmptyStateTone.error,
                actionLabel: 'Reintentar',
                onAction: () => ref.invalidate(currentDriverProvider),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.xl),
              child: TextButton(
                onPressed: () => signOutDriver(ref),
                child: const Text('Cerrar sesión'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
