import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';

part 'app_user.freezed.dart';
part 'app_user.g.dart';

/// A customer profile at `users/{uid}`.
///
/// Only a whitelist of these fields is writable from the app — see
/// `firestore.rules`. Everything moderation-related ([blocked],
/// [activeServiceId]) is written by Cloud Functions alone, so a modified
/// client cannot unblock itself or claim somebody else's service.
@freezed
abstract class AppUser with _$AppUser {
  const factory AppUser({
    required String id,
    required String phone,
    @Default('') String name,
    @Default('') String email,

    /// RNC turns the receipt into a "crédito fiscal" (NCF type 01) instead of
    /// the default "consumo" (02).
    @Default('') String rnc,

    /// Where the customer usually keeps the car. Free text rather than a
    /// geocoded point: it is typed once at registration to save repeating it,
    /// and the real pickup is still picked on the map at request time.
    @Default('') String address,
    @Default('') String photoUrl,
    @JsonKey(unknownEnumValue: UserRole.unknown)
    @Default(UserRole.client) UserRole role,
    @Default('es_DO') String locale,

    /// Set by an admin. A blocked user can sign in but cannot request.
    @Default(false) bool blocked,
    @Default('') String blockedReason,

    /// Denormalised pointer so the app can deep-link straight back into a
    /// service in flight without a query.
    String? activeServiceId,

    @JsonKey(unknownEnumValue: PaymentMethod.unknown)
    @Default(PaymentMethod.cash) PaymentMethod preferredPaymentMethod,
    @Default(0) int completedServices,

    /// How choferes rated this customer: server-written, and outside the
    /// fields the customer may update.
    @Default(0) int ratingSum,
    @Default(0) int ratingCount,

    /// How often choferes gave each [ClientRatingTag], by wire.
    @Default(<String, int>{}) Map<String, int> ratingTags,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
    @NullableTimestampConverter() DateTime? termsAcceptedAt,
    @Default('') String termsVersionAccepted,
  }) = _AppUser;

  const AppUser._();

  factory AppUser.fromJson(Map<String, dynamic> json) => _$AppUserFromJson(json);

  bool get hasProfile => name.trim().isNotEmpty;

  bool get canRequestService => !blocked && hasProfile;

  bool get billsWithRnc => rnc.trim().isNotEmpty;

  NcfType get ncfType => billsWithRnc ? NcfType.creditoFiscal : NcfType.consumo;

  /// First name only, for greetings that should not shout a full legal name.
  /// What choferes gave this customer on average, 0 before the first rating.
  double get averageRating => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  String get shortName {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Cliente';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  /// `+1 809 555 1234` -> `809-555-1234`, the form Dominicans read fastest.
  String get displayPhone {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('1')) {
      final d = digits.substring(1);
      return '${d.substring(0, 3)}-${d.substring(3, 6)}-${d.substring(6)}';
    }
    if (digits.length == 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return phone;
  }
}
