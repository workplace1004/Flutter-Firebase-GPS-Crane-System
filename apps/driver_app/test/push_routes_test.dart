import 'package:driver_app/push_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an offer opens home, where it rings', () {
    expect(driverRouteForPush({'type': 'offer', 'serviceId': 's1'}), '/');
  });

  test('an assignment from the office opens the job', () {
    expect(
      driverRouteForPush({'type': 'assigned', 'serviceId': 's1'}),
      '/servicio',
    );
  });

  test('a corte opens that corte', () {
    expect(
      driverRouteForPush({'type': 'driver_settlement', 'settlementId': 'c1'}),
      '/cortes/c1',
    );
  });

  test('messages open their conversation', () {
    expect(
      driverRouteForPush({'type': 'chat', 'serviceId': 's1'}),
      '/servicio/s1/chat',
    );
    expect(
      driverRouteForPush({'type': 'chat_request', 'requestId': 'r1'}),
      '/chat-solicitud/r1',
    );
  });

  test('anything unknown leaves the app where it opens', () {
    expect(driverRouteForPush({'type': 'something_new'}), isNull);
  });
}
