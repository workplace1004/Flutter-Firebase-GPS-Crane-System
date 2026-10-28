import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/registration_controller.dart';
import 'push_routes.dart';
import 'router.dart';

/// Messages that outlive the screen they came from: the code screen is gone by
/// the time the registration answers are saved, so it cannot show the result.
final _messenger = GlobalKey<ScaffoldMessengerState>();

/// Writes the register form's answers onto the account that just signed in.
///
/// Here at the root rather than on the code screen: the router leaves that
/// screen the moment the sign-in lands, and Android's instant verification
/// signs in without ever opening it.
Future<void> _applyRegistration(WidgetRef ref) async {
  final result =
      await ref.read(registrationControllerProvider.notifier).apply();
  final messenger = _messenger.currentState;
  if (messenger == null) return;

  result.fold(
    (hadAccount) {
      if (!hadAccount) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Ya tenías una cuenta con este número. Entraste a ella y '
            'conservamos tus datos.',
          ),
          duration: Duration(seconds: 8),
        ),
      );
    },
    (failure) => messenger.showSnackBar(
      SnackBar(
        content: Text(
          'No pudimos guardar todos tus datos del registro. '
          '${failure.userMessage}',
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Reintentar',
          onPressed: () => _applyRegistration(ref),
        ),
      ),
    ),
  );
}

class ClientApp extends ConsumerWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    // Watched, not read: a customer who has just signed in has no `users/`
    // document until the server makes one, and every screen that reads a
    // profile waits forever without it. Watching from the root means it runs
    // on a fresh sign-in and on a cold start of an existing session alike.
    ref
      ..watch(ensureProfileProvider)
      ..listen(currentUserIdProvider, (previous, uid) {
        if (previous == null && uid != null) unawaited(_applyRegistration(ref));
      });

    return MaterialApp.router(
      scaffoldMessengerKey: _messenger,
      title: config.flavor.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.phone(),
      routerConfig: ref.watch(routerProvider),
      locale: GruaLocalization.spanishDominican,
      supportedLocales: GruaLocalization.supportedLocales,
      localizationsDelegates: GruaLocalization.delegates,
      localeListResolutionCallback: GruaLocalization.resolve,
      builder: (context, child) {
        // Clamp text scaling: the request and tracking screens carry an
        // address and a price that must stay readable together, and Android's
        // largest accessibility setting otherwise pushes the price off-screen.
        final scale = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.3,
        );
        return webPhoneFrame(
          context,
          MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scale),
            // Registers this phone for push while somebody is signed in, and
            // opens the screen a tapped notification is about.
            child: PushBinding(
              audience: PushAudience.client,
              onOpen: (data) {
                final route = clientRouteForPush(data);
                if (route != null) ref.read(routerProvider).go(route);
              },
              // Above the navigator, so a call rings on whatever screen is
              // open and carries on when the person moves between screens.
              child: CallLayer(child: child ?? const SizedBox.shrink()),
            ),
          ),
        );
      },
    );
  }
}
