import 'package:client_app/push_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tow update opens the tracking screen', () {
    for (final type in [
      'driver_assigned',
      'driver_arrived',
      'service_started',
      'redispatching',
      'heavy_confirmed',
    ]) {
      expect(
        clientRouteForPush({'type': type, 'serviceId': 's1'}),
        '/servicio?id=s1',
        reason: type,
      );
    }
  });

  test('a finished tow opens its receipt in the history', () {
    expect(
      clientRouteForPush({'type': 'service_completed', 'serviceId': 's1'}),
      '/historial/s1',
    );
  });

  test('messages open their conversation', () {
    expect(
      clientRouteForPush({'type': 'chat', 'serviceId': 's1'}),
      '/servicio/s1/chat',
    );
    expect(
      clientRouteForPush({'type': 'chat_request_message', 'requestId': 'r1'}),
      '/chat-solicitud/r1',
    );
  });

  test('anything unknown leaves the app where it opens', () {
    expect(clientRouteForPush({'type': 'something_new'}), isNull);
    expect(clientRouteForPush(const {}), isNull);
  });
}
