import 'router.dart';

/// Where a tapped notification takes the customer, from its `data` (see the
/// `notify` calls in `functions/src`). Null leaves the app where it opens.
String? clientRouteForPush(Map<String, String> data) {
  final serviceId = data['serviceId'];
  final requestId = data['requestId'];
  final hasService = serviceId != null && serviceId.isNotEmpty;
  final hasRequest = requestId != null && requestId.isNotEmpty;

  switch (data['type']) {
    case 'chat':
      return hasService ? Routes.chatFor(serviceId) : Routes.chats;
    case 'chat_request':
    case 'chat_request_message':
      return hasRequest ? Routes.chatRequestFor(requestId) : Routes.chats;
    case 'service_completed':
      return hasService ? Routes.detailFor(serviceId) : Routes.history;
    case 'driver_assigned':
    case 'driver_arrived':
    case 'service_started':
    case 'redispatching':
    case 'heavy_confirmed':
      return hasService ? Routes.trackingFor(serviceId) : Routes.home;
    case 'incoming_call':
    case 'missed_call':
      // The call itself rings over any screen; this is only where it was about.
      if (hasService) return Routes.trackingFor(serviceId);
      if (hasRequest) return Routes.chatRequestFor(requestId);
      return null;
  }
  return null;
}
