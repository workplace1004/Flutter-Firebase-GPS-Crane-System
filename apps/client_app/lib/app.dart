import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'push_routes.dart';
import 'router.dart';

class ClientApp extends ConsumerWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    // Watched, not read: a customer who has just signed in has no `users/`
    // document until the server makes one, and every screen that reads a
    // profile waits forever without it. Watching from the root means it runs
    // on a fresh sign-in and on a cold start of an existing session alike.
    ref.watch(ensureProfileProvider);

    return MaterialApp.router(
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
