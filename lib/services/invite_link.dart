/// A shared invite: the inviter's stable address, plus optional two-way data.
class Invite {
  const Invite({required this.code, this.twoWay = false, this.token});
  final String code;
  final bool twoWay;
  final String? token;
}

const String inviteBaseUrl = 'https://thalionn.github.io/veilgrid/link/';

String buildInviteLink(String address, {bool twoWay = false, String? token}) {
  return Uri.parse(inviteBaseUrl).replace(queryParameters: {
    'code': address,
    if (twoWay) 'two': '1',
    if (twoWay && token != null && token.isNotEmpty) 't': token,
  }).toString();
}

/// Accepts a raw record key, a veilgrid:// link, or the shared https link.
Invite? parseInvite(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.scheme == 'veilgrid' || uri.scheme == 'http' || uri.scheme == 'https')) {
    final params = <String, String>{...uri.queryParameters};
    if (uri.fragment.isNotEmpty && !params.containsKey('code')) {
      final frag = Uri.splitQueryString(uri.fragment);
      params.addAll(frag);
    }
    final code = params['code'];
    if (code != null && code.isNotEmpty) {
      return Invite(
        code: code,
        twoWay: params['two'] == '1',
        token: params['t'],
      );
    }
    // veilgrid://link?code=... is covered above; anything else is not an invite.
    return null;
  }
  return Invite(code: value);
}
