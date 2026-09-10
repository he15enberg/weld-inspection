// Settings.
//
// The server section is real and is the only way to change where captures go.
// The rest is laid out but inert, and says so — an inspection app whose
// thresholds and standards look configurable but silently are not is worse than
// one that admits the gap.

import 'package:flutter/material.dart';

import 'api.dart';
import 'settings.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _conf = TextEditingController();
  final _rotate = TextEditingController();
  final _crop = TextEditingController();

  String? _probe;
  bool _probing = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    Settings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _url.text = s.url;
        _token.text = s.token;
        _conf.text = s.conf.toStringAsFixed(2);
        _rotate.text = s.rotate.toString();
        _crop.text = s.crop.toString();
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _conf.dispose();
    _rotate.dispose();
    _crop.dispose();
    super.dispose();
  }

  /// Reachability, checked here rather than discovered after a capture has been
  /// taken and thrown away. Reports whether the server answered AND whether the
  /// model is loaded, which are different failures with different fixes.
  Future<void> _test() async {
    setState(() {
      _probing = true;
      _probe = null;
    });
    final ok = await Api(_url.text, token: _token.text).health();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probe = ok ? 'Reachable, model loaded' : 'No answer, or model not loaded';
    });
  }

  Future<void> _save() async {
    // A bad number falls back to the default rather than blocking the save: a
    // typo in a threshold field should not strand the operator on a screen.
    final conf = Settings.clampConf(
        double.tryParse(_conf.text.trim()) ?? Settings.defaultConf);
    final rotate = _quarter(
        int.tryParse(_rotate.text.trim()) ?? Settings.defaultRotate);
    final crop = int.tryParse(_crop.text.trim()) ?? Settings.defaultCrop;

    await Settings.save(url: _url.text, token: _token.text,
        conf: conf, rotate: rotate, crop: crop);
    if (!mounted) return;
    // Write the accepted values back into the fields, so a clamped or snapped
    // entry is visible instead of the screen showing something untrue.
    setState(() {
      _dirty = false;
      _conf.text = conf.toStringAsFixed(2);
      _rotate.text = rotate.toString();
      _crop.text = crop.toString();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved · conf $conf · rotate $rotate'
          '${crop > 0 ? ' · crop $crop' : ' · no crop'}')),
    );
  }

  /// Rotation is only meaningful in quarter turns, and the server rounds to one
  /// anyway -- so round here too, where it can be seen.
  static int _quarter(int deg) => ((deg / 90).round() * 90) % 360;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            const PageTitle(
              title: 'Settings',
              subtitle: 'Where captures go, and how they are judged',
            ),
            _Section(
              title: 'Server',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => setState(() {
                      _dirty = true;
                      _probe = null;
                    }),
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: 'abc-def.trycloudflare.com',
                      helperText:
                          'https:// is assumed. A quick tunnel issues a new '
                          'hostname each restart, so expect to paste it again.',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _token,
                    autocorrect: false,
                    onChanged: (_) => setState(() {
                      _dirty = true;
                      _probe = null;
                    }),
                    decoration: const InputDecoration(
                      labelText: 'Token',
                      helperText: 'Only if the server sets WELDZ_TOKEN.',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _probing ? null : _test,
                          icon: _probing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_tethering, size: 16),
                          label: Text(_probing ? 'Testing' : 'Test'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _dirty ? _save : null,
                          child: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                  if (_probe != null) ...[
                    const SizedBox(height: 11),
                    Row(
                      children: [
                        Icon(
                          _probe!.startsWith('Reachable')
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 15,
                          color: _probe!.startsWith('Reachable')
                              ? WeldzColors.good
                              : WeldzColors.bad,
                        ),
                        const SizedBox(width: 8),
                        Text(_probe!,
                            style: TextStyle(
                              fontSize: 12,
                              color: _probe!.startsWith('Reachable')
                                  ? WeldzColors.good
                                  : WeldzColors.bad,
                            )),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            _Section(
              title: 'Model',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _conf,
                    autocorrect: false,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() => _dirty = true),
                    decoration: InputDecoration(
                      labelText: 'Confidence threshold',
                      helperMaxLines: 4,
                      helperText:
                          'Kept between ${Settings.confMin} and '
                          '${Settings.confMax}. 0.25 is what the model was '
                          'scored at. Lowering it does not uncover hidden '
                          'defects — on real captures the median defect sits '
                          'at 0.135, so 0.10 mostly admits boxes on whatever '
                          'else is on the bench.',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _rotate,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() => _dirty = true),
                    decoration: const InputDecoration(
                      labelText: 'Rotate before inference (degrees)',
                      helperMaxLines: 4,
                      helperText:
                          '270 for this phone. ARKit hands over the camera '
                          'buffer sideways and nothing corrects it, so the '
                          'part reaches the model on its end. 270 finds the '
                          'weld seam in 9 of 9 test frames against 3 of 9 '
                          'untouched — but 90 costs confidence, so the '
                          'direction matters.',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _crop,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() => _dirty = true),
                    decoration: const InputDecoration(
                      labelText: 'Square crop (pixels, 0 for none)',
                      helperMaxLines: 4,
                      helperText:
                          'The model only ever saw square images. The server '
                          'snaps this down so the crop edges land on whole '
                          'depth pixels — ask for 1392 and you get 1380 — '
                          'because a crop that splits a depth pixel puts '
                          'colour and depth out of step and spoils every '
                          'millimetre.',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _dirty ? _save : null,
                          child: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const _Section(
              title: 'Inspection',
              note: 'Not wired yet',
              child: Column(
                children: [
                  _Inert(
                    icon: Icons.straighten,
                    label: 'Material thickness',
                    value: '6.0 mm',
                    why: 'Every acceptance limit is expressed against thickness, '
                        'and it cannot be measured from one view.',
                  ),
                  Divider(height: 22),
                  _Inert(
                    icon: Icons.workspace_premium_outlined,
                    label: 'Quality level',
                    value: 'C',
                    why: 'ISO 5817 B / C / D. Tightens or relaxes every limit.',
                  ),
                ],
              ),
            ),
            const _Section(
              title: 'About',
              child: Column(
                children: [
                  _Inert(
                      icon: Icons.memory,
                      label: 'Model',
                      value: 'RF-DETR Seg · 8 classes'),
                  Divider(height: 22),
                  _Inert(
                      icon: Icons.photo_size_select_large_outlined,
                      label: 'Inference size',
                      value: '1272 x 1272'),
                  Divider(height: 22),
                  _Inert(
                      icon: Icons.sensors,
                      label: 'Depth',
                      value: 'ARKit sceneDepth · 256 x 192'),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.note});

  final String title;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 9),
              child: Row(
                children: [
                  Text(title.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.1,
                        color: WeldzColors.textDim,
                      )),
                  if (note != null) ...[
                    const SizedBox(width: 8),
                    Text(note!,
                        style: const TextStyle(
                            fontSize: 10, color: WeldzColors.textFaint)),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: WeldzColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: WeldzColors.border),
              ),
              child: child,
            ),
          ],
        ),
      );
}

/// A row that shows a value it cannot yet change. [why] explains what the
/// setting would do, so the placeholder is informative rather than decorative.
class _Inert extends StatelessWidget {
  const _Inert({
    required this.icon,
    required this.label,
    required this.value,
    this.why,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? why;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: WeldzColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13.5)),
                if (why != null) ...[
                  const SizedBox(height: 3),
                  Text(why!,
                      style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.35,
                          color: WeldzColors.textFaint)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(value, style: weldzMono(size: 12, color: WeldzColors.textDim)),
        ],
      );
}
