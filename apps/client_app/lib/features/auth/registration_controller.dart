import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// What the register form collected, held until the SMS code proves the
/// account it belongs to.
///
/// Nothing can be written at the moment the form is submitted: Firebase has no
/// account until the code is confirmed, and the security rules refuse a
/// client-created `users/` document even then. So the answers wait here and are
/// applied once, immediately after sign-in.
class RegistrationDraft {
  const RegistrationDraft({
    required this.name,
    required this.email,
    required this.address,
    required this.make,
    required this.model,
    required this.plate,
  });

  final String name;
  final String email;
  final String address;
  final String make;
  final String model;
  final String plate;

  /// The vehicle block is optional, and any one of the three fields is enough
  /// to be worth keeping — a customer who types only a plate still told us
  /// something the chofer can use.
  bool get hasVehicle =>
      make.isNotEmpty || model.isNotEmpty || plate.isNotEmpty;

  ServiceVehicle get vehicle =>
      ServiceVehicle(make: make, model: model, plate: plate);
}

class RegistrationController extends Notifier<RegistrationDraft?> {
  @override
  RegistrationDraft? build() => null;

  /// Keeps the form's answers until [apply] can write them.
  void remember({
    required String name,
    required String email,
    required String address,
    required String make,
    required String model,
    required String plate,
  }) {
    state = RegistrationDraft(
      name: name,
      email: email,
      address: address,
      make: make,
      model: model,
      plate: plate,
    );
  }

  void clear() => state = null;

  /// Writes the held answers onto the account that has just signed in.
  ///
  /// Order matters. The server must create the `users/` document before the
  /// client is allowed to update it, so `ensureProfile` runs first and is
  /// awaited here rather than left to the root provider, whose timing this
  /// flow cannot depend on.
  ///
  /// Registering with a number that already has an account signs in to that
  /// account: the SMS proved the phone is theirs. Its name, email and address
  /// are kept and only empty ones are filled from the form, and the vehicle is
  /// added beside the ones already saved instead of replacing the first.
  ///
  /// Returns ok(true) when that happened, so the customer can be told they
  /// were already registered. Returns ok(false) when there was nothing held,
  /// so it is safe to run after every sign-in.
  Future<Result<bool>> apply() async {
    final draft = state;
    if (draft == null) return const Result.ok(false);

    final uid = ref.read(authRepositoryProvider).currentUserId;
    if (uid == null) {
      return const Result.err(Failure(FailureCode.unauthenticated));
    }

    final created = await ref.read(functionsGatewayProvider).ensureProfile();
    if (created case Err(:final failure)) return Result.err(failure);

    final users = ref.read(userRepositoryProvider);
    final existing = (await users.fetchUser(uid)).valueOrNull;
    final hadAccount = existing?.hasProfile ?? false;

    String? fill(String? current, String typed) =>
        (current ?? '').trim().isEmpty ? typed : null;

    final saved = await users.updateProfile(
      uid,
      name: hadAccount ? fill(existing!.name, draft.name) : draft.name,
      email: hadAccount ? fill(existing!.email, draft.email) : draft.email,
      address:
          hadAccount ? fill(existing!.address, draft.address) : draft.address,
    );
    if (saved case Err(:final failure)) return Result.err(failure);

    if (draft.hasVehicle) {
      final stored = hadAccount
          ? await users.saveVehicle(
              uid,
              draft.vehicle,
              id: 'registro-${DateTime.now().millisecondsSinceEpoch}',
            )
          : await users.saveVehicle(uid, draft.vehicle);
      if (stored case Err(:final failure)) return Result.err(failure);
    }

    // Only cleared once everything landed, so a retry still has the answers.
    state = null;
    return Result.ok(hadAccount);
  }
}

final registrationControllerProvider =
    NotifierProvider<RegistrationController, RegistrationDraft?>(
  RegistrationController.new,
);
