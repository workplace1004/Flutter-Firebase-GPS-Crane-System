/// The public pages Google Play links to, which the apps must link to too.
///
/// Served with the operations panel: the files live in
/// `apps/admin_web/web/`, so they go up with every panel upload.
abstract final class LegalLinks {
  static final Uri privacyPolicy =
      Uri.parse('https://titangruasrd.com.do/privacidad.html');

  static final Uri accountDeletion =
      Uri.parse('https://titangruasrd.com.do/eliminar-cuenta.html');
}
