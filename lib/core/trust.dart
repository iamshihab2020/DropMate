import 'sanitize.dart';

enum TrustState { none, proposedByMe, proposedByThem, active }

class Limits {
  final int maxBytes;
  final Set<String> kinds; // empty = all kinds; else subset of {image, video, audio, document, archive, other}

  const Limits({this.maxBytes = 5 * 1024 * 1024 * 1024, this.kinds = const {}});

  Map<String, dynamic> toJson() => {'max': maxBytes, 'kinds': kinds.toList()};
  factory Limits.fromJson(Map<String, dynamic>? j) =>
      j == null ? const Limits() : Limits(maxBytes: j['max'], kinds: {...(j['kinds'] as List).cast<String>()});
}

String kindOf(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const m = {
    'image': {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'},
    'video': {'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'},
    'audio': {'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac', 'opus'},
    'document': {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv'},
    'archive': {'zip', 'rar', '7z', 'tar', 'gz'},
  };
  for (final e in m.entries) {
    if (e.value.contains(ext)) return e.key;
  }
  return 'other';
}

/// Mutual auto-accept between me and one contact (PRD §11.8).
class Trust {
  final TrustState state;
  final Limits mine;
  final Limits theirs;
  final int rev;

  const Trust({this.state = TrustState.none, this.mine = const Limits(), this.theirs = const Limits(), this.rev = 0});

  Trust _to(TrustState s, {Limits? mine, Limits? theirs, int? rev}) =>
      Trust(state: s, mine: mine ?? this.mine, theirs: theirs ?? this.theirs, rev: rev ?? this.rev + 1);

  /// I tap "Skip approval between us".
  Trust propose(Limits my) => switch (state) {
    TrustState.proposedByThem || TrustState.active => _to(TrustState.active, mine: my),
    _ => _to(TrustState.proposedByMe, mine: my),
  };

  /// They proposed. Simultaneous proposals → active.
  Trust onTheirPropose(Limits their, int theirRev) {
    if (theirRev <= rev && state != TrustState.proposedByMe) return this;
    return state == TrustState.proposedByMe
        ? _to(TrustState.active, theirs: their, rev: _max(theirRev))
        : _to(TrustState.proposedByThem, theirs: their, rev: _max(theirRev));
  }

  /// I agree to their proposal.
  Trust accept(Limits my) => state == TrustState.proposedByThem ? _to(TrustState.active, mine: my) : this;

  Trust onTheirAccept(Limits their, int theirRev) =>
      state == TrustState.proposedByMe ? _to(TrustState.active, theirs: their, rev: _max(theirRev)) : this;

  /// Either side, any time, no agreement needed.
  Trust revoke() => _to(TrustState.none);
  Trust onTheirRevoke(int theirRev) => _to(TrustState.none, rev: _max(theirRev));

  int _max(int r) => (r > rev ? r : rev) + 1;

  /// Receiver-side check: may this incoming transfer skip the prompt?
  bool allows(List<({String name, int size})> files) {
    if (state != TrustState.active) return false;
    final total = files.fold<int>(0, (a, f) => a + f.size);
    if (total > mine.maxBytes) return false;
    for (final f in files) {
      if (isExecutable(f.name)) return false;
      if (mine.kinds.isNotEmpty && !mine.kinds.contains(kindOf(f.name))) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {'state': state.name, 'mine': mine.toJson(), 'theirs': theirs.toJson(), 'rev': rev};
  factory Trust.fromJson(Map<String, dynamic>? j) => j == null
      ? const Trust()
      : Trust(
          state: TrustState.values.byName(j['state']),
          mine: Limits.fromJson(j['mine']),
          theirs: Limits.fromJson(j['theirs']),
          rev: j['rev'],
        );
}
