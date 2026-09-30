import 'package:grua_core/grua_core.dart';

import 'app.dart';
import 'firebase_options.dart';

/// Entry point for the chofer app. The role comes from the signed-in user's
/// custom claims.
void main() => runGruaApp(
      appKind: AppKind.driver,
      builder: DriverApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
    );
