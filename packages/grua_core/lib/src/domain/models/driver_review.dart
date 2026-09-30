import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../enums.dart';

/// A customer's review of the chofer who towed them, at
/// `driverReviews/{serviceId}`: one per rated service.
///
/// Server-written by `rateService`, and the office's only — it names the
/// customer. The chofer reads an anonymous copy on their own record
/// (`Driver.recentFeedback`).
@immutable
class DriverReview {
  const DriverReview({
    required this.serviceId,
    required this.driverId,
    required this.stars,
    this.serviceCode = '',
    this.driverName = '',
    this.clientId = '',
    this.clientName = '',
    this.tags = const [],
    this.comment = '',
    this.status = DriverReviewStatus.ok,
    this.ratedAt,
    this.resolutionNote = '',
    this.resolvedBy = '',
    this.resolvedAt,
  });

  factory DriverReview.fromJson(Map<String, dynamic> json) {
    const time = NullableTimestampConverter();
    return DriverReview(
      serviceId: json['serviceId'] as String? ?? '',
      serviceCode: json['serviceCode'] as String? ?? '',
      driverId: json['driverId'] as String? ?? '',
      driverName: json['driverName'] as String? ?? '',
      clientId: json['clientId'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      stars: (json['stars'] as num?)?.toInt() ?? 0,
      tags: [
        for (final tag in (json['tags'] as List<dynamic>?) ?? const [])
          if (tag is String) tag,
      ],
      comment: json['comment'] as String? ?? '',
      status: DriverReviewStatus.fromWire(json['status'] as String?),
      ratedAt: time.fromJson(json['ratedAt']),
      resolutionNote: json['resolutionNote'] as String? ?? '',
      resolvedBy: json['resolvedBy'] as String? ?? '',
      resolvedAt: time.fromJson(json['resolvedAt']),
    );
  }

  final String serviceId;
  final String serviceCode;
  final String driverId;
  final String driverName;
  final String clientId;
  final String clientName;
  final int stars;

  /// [DriverRatingTag] wires.
  final List<String> tags;
  final String comment;
  final DriverReviewStatus status;
  final DateTime? ratedAt;

  /// What the office found, once it has looked.
  final String resolutionNote;
  final String resolvedBy;
  final DateTime? resolvedAt;

  bool get isOpen => status == DriverReviewStatus.open;

  List<DriverRatingTag> get ratingTags => [
        for (final wire in tags)
          if (DriverRatingTag.fromWire(wire) case final tag
              when tag != DriverRatingTag.unknown)
            tag,
      ];

  DriverReview copyWith({
    DriverReviewStatus? status,
    String? resolutionNote,
    String? resolvedBy,
    DateTime? resolvedAt,
  }) =>
      DriverReview(
        serviceId: serviceId,
        serviceCode: serviceCode,
        driverId: driverId,
        driverName: driverName,
        clientId: clientId,
        clientName: clientName,
        stars: stars,
        tags: tags,
        comment: comment,
        status: status ?? this.status,
        ratedAt: ratedAt,
        resolutionNote: resolutionNote ?? this.resolutionNote,
        resolvedBy: resolvedBy ?? this.resolvedBy,
        resolvedAt: resolvedAt ?? this.resolvedAt,
      );
}
