import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Where a call between a customer and their chofer stands.
///
/// Mirrors `CallState` in `functions/src/lib/calls.ts`, which is the only
/// thing that ever writes it.
enum CallState {
  ringing('ringing'),
  accepted('accepted'),
  declined('declined'),
  missed('missed'),
  cancelled('cancelled'),
  ended('ended'),
  unknown('unknown');

  const CallState(this.wire);

  final String wire;

  static CallState fromWire(String? wire) =>
      values.firstWhere((s) => s.wire == wire, orElse: () => CallState.unknown);

  bool get isOver =>
      this != CallState.ringing && this != CallState.accepted && this != unknown;
}

/// Why a party is ending a call. The server decides what that makes the call.
enum EndCallReason {
  hangup('hangup'),
  declined('declined'),
  missed('missed'),
  cancelled('cancelled');

  const EndCallReason(this.wire);

  final String wire;
}

/// One call, as `calls/{id}` stores it.
@immutable
class VoiceCall {
  const VoiceCall({
    required this.id,
    required this.serviceId,
    required this.state,
    required this.callerId,
    required this.callerName,
    required this.calleeId,
    required this.calleeName,
    this.chatRequestId = '',
    this.video = false,
    this.createdAt,
    this.answeredAt,
  });

  factory VoiceCall.fromJson(String id, Map<String, dynamic> json) {
    DateTime? at(Object? value) => switch (value) {
          final Timestamp t => t.toDate().toUtc(),
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
          final DateTime d => d.toUtc(),
          _ => null,
        };

    return VoiceCall(
      id: id,
      serviceId: json['serviceId'] as String? ?? '',
      chatRequestId: json['chatRequestId'] as String? ?? '',
      state: CallState.fromWire(json['state'] as String?),
      callerId: json['callerId'] as String? ?? '',
      callerName: json['callerName'] as String? ?? '',
      calleeId: json['calleeId'] as String? ?? '',
      calleeName: json['calleeName'] as String? ?? '',
      video: json['video'] == true,
      createdAt: at(json['createdAt']),
      answeredAt: at(json['answeredAt']),
    );
  }

  final String id;

  /// The service the call is on. Empty for a call in a pre-job chat.
  final String serviceId;

  /// The conversation opened from a nearby truck the call is in, before any
  /// job. Empty for a call on a service.
  final String chatRequestId;

  final CallState state;
  final String callerId;
  final String callerName;
  final String calleeId;
  final String calleeName;

  /// Camera as well as microphone, both ways. Chosen by the caller.
  final bool video;

  final DateTime? createdAt;
  final DateTime? answeredAt;

  /// The name to show to [uid]: the other person.
  String peerNameFor(String uid) => uid == callerId ? calleeName : callerName;

  /// A ringing call old enough that nobody is still on the other end.
  ///
  /// The server moves a call that rings out to `missed`, but only when the
  /// caller's app is there to ask. One whose caller vanished mid-ring would
  /// otherwise ring on the other phone indefinitely.
  bool isStale(DateTime now) {
    final created = createdAt;
    return created != null && now.difference(created) > ringLimit;
  }

  /// Matches `RING_TIMEOUT_MS` on the server.
  static const ringLimit = Duration(seconds: 45);

  VoiceCall copyWith({CallState? state, DateTime? answeredAt}) => VoiceCall(
        id: id,
        serviceId: serviceId,
        chatRequestId: chatRequestId,
        state: state ?? this.state,
        callerId: callerId,
        callerName: callerName,
        calleeId: calleeId,
        calleeName: calleeName,
        video: video,
        createdAt: createdAt,
        answeredAt: answeredAt ?? this.answeredAt,
      );
}

/// What the server hands a party joining a call: where to connect, and the
/// pass to get in.
@immutable
class CallJoin {
  const CallJoin({
    required this.callId,
    required this.peerName,
    required this.url,
    required this.token,
    this.video = false,
  });

  final String callId;
  final String peerName;
  final bool video;

  /// The LiveKit server, `wss://…`. Empty in a test, where there is no
  /// audio to connect to.
  final String url;
  final String token;
}

/// Watches calls. Read-only: every write goes through the gateway.
abstract interface class CallRepository {
  /// A call ringing for [uid] right now, or null.
  Stream<VoiceCall?> watchIncomingCall(String uid);

  Stream<VoiceCall?> watchCall(String callId);
}
