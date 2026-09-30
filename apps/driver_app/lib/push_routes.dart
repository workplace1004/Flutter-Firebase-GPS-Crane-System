import 'router.dart';

/// Where a tapped notification takes the chofer, from its `data` (see the
/// `notify` and `sendOffer` calls in `functions/src`). Null leaves the app
/// where it opens.
String? driverRouteForPush(Map<String, String> data) {
  final serviceId = data['serviceId'];
  final requestId = data['requestId'];
  final hasService = serviceId != null && serviceId.isNotEmpty;
  final hasRequest = requestId != null && requestId.isNotEmpty;

  switch (data['type']) {
    // The offer rings on the home screen, if it is still open.
    case 'offer':
    case 'service_cancelled':
      return Routes.home;
    case 'assigned':
      return Routes.activeService;
    case 'chat':
      return hasService ? Routes.chatFor(serviceId) : Routes.chats;
    case 'chat_request':
    case 'chat_request_message':
      return hasRequest ? Routes.chatRequestFor(requestId) : Routes.chats;
    case 'driver_settlement':
      final id = data['settlementId'];
      return id == null || id.isEmpty
          ? Routes.settlements
          : Routes.settlementFor(id);
    case 'incoming_call':
    case 'missed_call':
      // The call itself rings over any screen; this is only where it was about.
      if (hasService) return Routes.activeService;
      if (hasRequest) return Routes.chatRequestFor(requestId);
      return null;
  }
  return null;
}
