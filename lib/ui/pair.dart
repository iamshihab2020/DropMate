import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/native.dart';
import '../services/pairing.dart';
import 'app.dart';
import 'i18n.dart';
import 'theme.dart';

/// Add a person, or link another of my devices (PRD §7.2, §7.3).
class PairScreen extends StatefulWidget {
  final bool link;
  const PairScreen({super.key, this.link = false});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  PairSession? _session;
  String? _error;
  bool _busy = false;
  bool _celebrate = false;

  @override
  void dispose() {
    final s = _session;
    if (s != null && s.stage != PairStage.done) context.engine.pairing.cancel();
    super.dispose();
  }

  void _watch(PairSession s) {
    setState(() => _session = s);
    s.addListener(() {
      if (!mounted) return;
      setState(() {});
      if (s.stage == PairStage.done && !_celebrate) {
        setState(() => _celebrate = true);
        Future.delayed(Duration(milliseconds: reducedMotion(context) ? 300 : 1400), () {
          if (mounted) Navigator.pop(context);
        });
      }
    });
  }

  Future<void> _join({String? qr, String? code}) async {
    if (_busy) return;
    final e = context.engine;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await e.pairing.join(qr: qr, code: code);
      if (s.mode == PairMode.link && e.contacts.isNotEmpty) {
        await e.pairing.confirm(s, false);
        throw const FormatException('This device already has people. Unpair them before linking it to another device.');
      }
      _watch(s);
    } on FormatException catch (err) {
      setState(() => _error = err.message);
    } catch (_) {
      setState(() => _error = 'Could not reach that device. Make sure you are on the same Wi-Fi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    if (s != null && _celebrate) return _Connected(session: s);
    if (s != null &&
        (s.stage == PairStage.confirm ||
            s.stage == PairStage.waiting ||
            s.stage == PairStage.failed && s.peer != null)) {
      return _ConfirmView(session: s, onRetry: () => setState(() => _session = null));
    }
    final canScan = Platform.isAndroid;
    final title = widget.link ? tr('Link my device') : tr('Add a person');
    final error = _error == null
        ? null
        : MaterialBanner(
            content: Text(_error!),
            leading: const Icon(Icons.error_outline),
            actions: [TextButton(onPressed: () => setState(() => _error = null), child: Text(tr('OK')))],
          );
    if (MediaQuery.sizeOf(context).width >= 760) {
      final t = Theme.of(context);
      Widget half(String heading, Widget child) => Expanded(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: t.colorScheme.outlineVariant),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Text(heading, style: t.textTheme.headlineSmall),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      );
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Column(
          children: [
            ?error,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    half(tr('Show my code'), _ShowCode(link: widget.link, onSession: _watch)),
                    half(
                      tr('Enter their code'),
                      _EnterCode(onCode: (c) => _join(code: c), busy: _busy, link: widget.link),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return DefaultTabController(
      length: canScan ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          bottom: TabBar(
            tabs: [
              Tab(text: tr('Show my code')),
              if (canScan) Tab(text: tr('Scan')),
              Tab(text: tr('Enter code')),
            ],
          ),
        ),
        body: Column(
          children: [
            ?error,
            Expanded(
              child: TabBarView(
                children: [
                  _ShowCode(link: widget.link, onSession: _watch),
                  if (canScan)
                    _Scan(
                      onCode: (v) => _join(qr: v),
                      busy: _busy,
                    ),
                  _EnterCode(
                    onCode: (c) => _join(code: c),
                    busy: _busy,
                    link: widget.link,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShowCode extends StatefulWidget {
  final bool link;
  final void Function(PairSession) onSession;
  const _ShowCode({required this.link, required this.onSession});

  @override
  State<_ShowCode> createState() => _ShowCodeState();
}

class _ShowCodeState extends State<_ShowCode> with AutomaticKeepAliveClientMixin {
  PairSession? _s;
  Timer? _tick;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  Future<void> _start() async {
    final s = await context.engine.pairing.show(widget.link ? PairMode.link : PairMode.contact);
    if (!mounted) return;
    setState(() => _s = s);
    s.addListener(() {
      if (s.stage == PairStage.confirm) widget.onSession(s);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = _s;
    final t = Theme.of(context);
    if (s == null) return const Center(child: CircularProgressIndicator());
    final left = Duration(milliseconds: (s.expiresAt - DateTime.now().millisecondsSinceEpoch).clamp(0, 1 << 31));
    final expired = left == Duration.zero || s.stage == PairStage.failed;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.link
                  ? 'On your other device, open DropMate and choose "Link another of my devices", then scan or enter this code.'
                  : 'On their device, tap Add person, then scan this or enter the code.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: expired ? 0.2 : 1,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Brand.lagoon, width: 3),
                ),
                child: Semantics(
                  label: tr('Pairing QR code'),
                  child: QrImageView(
                    data: s.qr,
                    size: 220,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Brand.deepwater),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.circle,
                      color: Brand.deepwater,
                    ),
                    embeddedImage: const AssetImage('assets/icon.png'),
                    embeddedImageStyle: const QrEmbeddedImageStyle(size: Size(44, 44)),
                    errorCorrectionLevel: QrErrorCorrectLevel.H,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            SelectableText(
              '${s.code.substring(0, 3)} ${s.code.substring(3)}',
              style: display(44).copyWith(letterSpacing: 6, color: t.colorScheme.primary),
            ),
            const SizedBox(height: 8),
            if (expired)
              FilledButton.tonal(onPressed: _start, child: Text(tr('New code')))
            else
              Text(
                tr('Expires in {time} · works once', {
                  'time': '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                }),
                style: t.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _Scan extends StatefulWidget {
  final void Function(String) onCode;
  final bool busy;
  const _Scan({required this.onCode, required this.busy});

  @override
  State<_Scan> createState() => _ScanState();
}

class _ScanState extends State<_Scan> {
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    Native.requestCameraPermission().then((ok) => mounted ? setState(() => _allowed = ok) : null);
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed == null) return const Center(child: CircularProgressIndicator());
    if (_allowed == false) {
      return Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text(tr('Allow the camera to scan, or use "Enter code".'))),
      );
    }
    return Stack(
      children: [
        MobileScanner(
          onDetect: (cap) {
            final v = cap.barcodes.firstOrNull?.rawValue;
            if (v != null && v.startsWith('dropmate://') && !widget.busy) widget.onCode(v);
          },
        ),
        if (widget.busy) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _EnterCode extends StatefulWidget {
  final void Function(String) onCode;
  final bool busy;
  final bool link;
  const _EnterCode({required this.onCode, required this.busy, required this.link});

  @override
  State<_EnterCode> createState() => _EnterCodeState();
}

class _EnterCodeState extends State<_EnterCode> {
  final _c = TextEditingController();

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.link
                  ? tr('Enter the code shown on your other device.')
                  : tr('Enter the 6-digit code shown on their device.'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _c,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: display(36).copyWith(letterSpacing: 10),
              decoration: const InputDecoration(hintText: '000000', counterText: ''),
              onChanged: (v) {
                if (v.length == 6) widget.onCode(v);
              },
            ),
            const SizedBox(height: 16),
            if (widget.busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
  );
}

class _ConfirmView extends StatelessWidget {
  final PairSession session;
  final VoidCallback onRetry;
  const _ConfirmView({required this.session, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    final s = session;
    final name = s.peer?.name ?? '';
    final device = s.peer?.devices.firstOrNull?.name ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(tr('Confirm'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.mode == PairMode.link
                    ? tr('Link {device} as your device?', {'device': device})
                    : tr('Connect with {name}?', {'name': name}),
                style: t.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(device, style: t.textTheme.bodyMedium),
              const SizedBox(height: 24),
              Semantics(
                label: tr('Check that both screens show the same four pictures'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < s.emojis.length; i++)
                      PopIn(
                        delay: Duration(milliseconds: 140 * i),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          width: 72,
                          height: 72,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: t.colorScheme.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: t.colorScheme.outlineVariant),
                          ),
                          child: Text(s.emojis[i], style: const TextStyle(fontSize: 38)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(tr('Both screens must show the same four pictures.'), textAlign: TextAlign.center),
              const SizedBox(height: 32),
              if (s.stage == PairStage.failed) ...[
                Text(s.error ?? 'Pairing failed', style: TextStyle(color: t.colorScheme.error)),
                const SizedBox(height: 12),
                FilledButton(onPressed: onRetry, child: Text(tr('Try again'))),
              ] else if (s.stage == PairStage.waiting)
                Column(
                  children: [
                    const CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(tr('Waiting for the other device…')),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(onPressed: () => e.pairing.confirm(s, false), child: Text(tr("They don't match"))),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: () => e.pairing.confirm(s, true), child: Text(tr('Confirm'))),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short moment of success: the other side's face pops in with a check.
class _Connected extends StatelessWidget {
  final PairSession session;
  const _Connected({required this.session});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final peer = session.peer;
    final link = session.mode == PairMode.link;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopIn(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  peer == null || link
                      ? Icon(Icons.devices_rounded, size: 96, color: t.colorScheme.primary)
                      : Avatar(id: peer.personId, name: peer.name, photo: peer.avatar, online: true, size: 112),
                  const Positioned(
                    right: -6,
                    bottom: -6,
                    child: PopIn(
                      delay: Duration(milliseconds: 300),
                      child: Icon(Icons.check_circle_rounded, size: 40, color: Color(0xFF00B39E)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              link ? tr('Device linked') : tr('You and {name} are connected', {'name': peer?.name ?? ''}),
              style: t.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
