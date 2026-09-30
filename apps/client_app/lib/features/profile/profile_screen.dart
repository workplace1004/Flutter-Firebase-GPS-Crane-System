import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final settings = ref.watch(appSettingsProvider).value;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mi cuenta'),
      ),
      // Three states, not two. Reading `.value` alone made an error and a
      // missing document both look like "still loading", which is how this
      // screen came to spin forever when the profile document did not exist.
      body: userAsync.when(
        loading: () => const BrandLoader(),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          title: 'No pudimos cargar tu perfil',
          message: error is Failure
              ? error.userMessage
              : 'Revisa tu conexión e intenta de nuevo.',
          actionLabel: 'Reintentar',
          onAction: () => _retry(ref),
        ),
        data: (user) => user == null
            ? EmptyState(
                icon: Icons.person_off_outlined,
                title: 'Tu perfil no está listo',
                message: 'Todavía estamos creando tu cuenta. Revisa tu '
                    'conexión e intenta de nuevo.',
                actionLabel: 'Reintentar',
                onAction: () => _retry(ref),
              )
            : ListView(
              padding: const EdgeInsets.all(Insets.lg),
              children: [
                FloatingCard(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: BrandColors.redTint,
                        child: Text(
                          user.shortName.isEmpty ? '?' : user.shortName[0],
                          style: text.headlineSmall
                              ?.copyWith(color: BrandColors.red),
                        ),
                      ),
                      const SizedBox(width: Insets.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.name, style: text.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              user.displayPhone,
                              style: text.bodyMedium
                                  ?.copyWith(color: BrandColors.grey600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.receipt_long_outlined,
                        label: 'Mis servicios',
                        onTap: () => context.go(Routes.history),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.credit_card_outlined,
                        label: 'Métodos de pago',
                        subtitle: user.preferredPaymentMethod.label,
                        onTap: () => _notYet(context),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.business_outlined,
                        label: 'Facturación',
                        subtitle: user.billsWithRnc
                            ? 'RNC ${user.rnc} · crédito fiscal'
                            : 'Consumo',
                        onTap: () => _notYet(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.support_agent_outlined,
                        label: 'Soporte 24/7',
                        subtitle: settings?.supportPhone ?? '',
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Llamando a ${settings?.supportPhone ?? 'soporte'}…',
                            ),
                          ),
                        ),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.description_outlined,
                        label: 'Términos y privacidad',
                        onTap: () => _notYet(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.xl),

                OutlinedButton.icon(
                  onPressed: () async {
                    // Before signing out, while the rules still allow it: the
                    // next person on this phone must not get these pushes.
                    final uid = ref.read(currentUserIdProvider);
                    if (uid != null) {
                      await ref
                          .read(pushServiceProvider)
                          .unregister(uid: uid, audience: PushAudience.client);
                    }
                    await ref.read(authRepositoryProvider).signOut();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrandColors.danger,
                    side: const BorderSide(color: BrandColors.dangerTint),
                  ),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Cerrar sesión'),
                ),
              ],
            ),
      ),
    );
  }

  /// Re-runs the server-side profile creation, then re-reads the document.
  ///
  /// Both halves matter: the retry is here because the document was missing,
  /// and only the callable can create one.
  Future<void> _retry(WidgetRef ref) async {
    await ref.read(functionsGatewayProvider).ensureProfile();
    ref.invalidate(currentUserProvider);
  }

  void _notYet(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disponible en la próxima versión.')),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: BrandColors.grey800),
      title: Text(label, style: Theme.of(context).textTheme.titleSmall),
      subtitle: subtitle == null || subtitle!.isEmpty
          ? null
          : Text(
              subtitle!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: BrandColors.grey600),
            ),
      trailing: const Icon(Icons.chevron_right, color: BrandColors.grey400),
    );
  }
}
