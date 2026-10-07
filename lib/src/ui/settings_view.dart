import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app/watcher_service.dart';
import '../data/settings.dart';
import '../mlflow/mlflow_client.dart';
import '../platform/autostart.dart';
import 'theme.dart';

/// The settings form, shown in the same window as the overlay.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.service, required this.onClose, this.movable = true});

  final WatcherService service;

  /// Called after Save (true) or Cancel (false).
  final void Function(bool saved) onClose;

  /// False in tests (no native window).
  final bool movable;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final Settings _initial = widget.service.settings;
  late final _url = TextEditingController(text: _initial.serverUrl);
  late final _username = TextEditingController(text: _initial.username);
  late final _secret = TextEditingController(text: widget.service.secret);
  late final _experiments = TextEditingController(text: _initial.experimentNames.join('\n'));
  late final _user = TextEditingController(text: _initial.userFilter);
  late final _epochMetric = TextEditingController(text: _initial.epochMetric);
  late final _totalParam = TextEditingController(text: _initial.totalEpochsParam);
  late final _stale = TextEditingController(text: '${_initial.staleMinutes}');
  late AuthMode _auth = _initial.authMode;
  late bool _untrusted = _initial.allowUntrustedCertificate;
  late int _opacity = _initial.opacityPercent;
  late bool _onTop = _initial.alwaysOnTop;
  late bool _autoGrow = _initial.autoGrowOverlay;
  late bool _notifyFailure = _initial.notifyOnFailure;
  late bool _notifyFinish = _initial.notifyOnFinish;
  bool? _autostart;
  bool? _autostartInitial;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    if (Autostart.isSupported) {
      Autostart.isEnabled().then((v) {
        if (mounted) setState(() => _autostart = _autostartInitial = v);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_url, _username, _secret, _experiments, _user, _epochMetric, _totalParam, _stale]) {
      c.dispose();
    }
    super.dispose();
  }

  Settings _collect() {
    String orDefault(TextEditingController c, String d) => c.text.trim().isEmpty ? d : c.text.trim();
    return _initial.copyWith(
      serverUrl: _url.text.trim(),
      authMode: _auth,
      username: _username.text.trim(),
      allowUntrustedCertificate: _untrusted,
      experimentNames: [
        for (final line in _experiments.text.split(RegExp(r'[\n,]')))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      userFilter: _user.text.trim(),
      epochMetric: orDefault(_epochMetric, 'epoch'),
      totalEpochsParam: orDefault(_totalParam, 'epochs'),
      staleMinutes: (int.tryParse(_stale.text.trim()) ?? _initial.staleMinutes).clamp(1, 10000),
      opacityPercent: _opacity,
      alwaysOnTop: _onTop,
      autoGrowOverlay: _autoGrow,
      notifyOnFailure: _notifyFailure,
      notifyOnFinish: _notifyFinish,
    );
  }

  String get _secretValue => _auth == AuthMode.none ? '' : _secret.text;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final error = await widget.service.testConnection(_collect(), _secretValue);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = error == null;
      _testResult = error ?? 'Connection OK';
    });
  }

  Future<void> _save() async {
    await widget.service.applySettings(_collect(), _secretValue);
    final autostart = _autostart;
    if (autostart != null && autostart != _autostartInitial) {
      try {
        await Autostart.setEnabled(autostart);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not change start at login: $e')));
        }
      }
    }
    widget.onClose(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Row(
      children: [
        const Icon(Icons.settings, size: 16, color: OverlayColors.accent),
        const SizedBox(width: 8),
        Text('mlwatcher settings', style: theme.textTheme.titleSmall),
      ],
    );
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            color: OverlayColors.header,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: widget.movable ? DragToMoveArea(child: SizedBox.expand(child: title)) : title,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Cancel',
                  onPressed: () => widget.onClose(false),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                _section('MLflow server'),
                _field(_url, 'Server URL', hint: 'http://mlflow.example.lan:5000'),
                const SizedBox(height: 10),
                SegmentedButton<AuthMode>(
                  segments: const [
                    ButtonSegment(value: AuthMode.none, label: Text('No auth')),
                    ButtonSegment(value: AuthMode.basic, label: Text('Password')),
                    ButtonSegment(value: AuthMode.token, label: Text('Token')),
                  ],
                  selected: {_auth},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _auth = s.first),
                ),
                if (_auth == AuthMode.basic) ...[const SizedBox(height: 10), _field(_username, 'Username')],
                if (_auth != AuthMode.none) ...[
                  const SizedBox(height: 10),
                  _field(
                    _secret,
                    _auth == AuthMode.basic ? 'Password' : 'Token',
                    obscure: true,
                    helper: 'Stored encrypted for your user account',
                  ),
                ],
                _check(
                  'Accept a self-signed certificate',
                  _untrusted,
                  (v) => setState(() => _untrusted = v),
                  subtitle: 'Only for this server, HTTPS only',
                ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering, size: 16),
                      label: const Text('Test connection'),
                    ),
                    const SizedBox(width: 12),
                    if (_testResult != null)
                      Expanded(
                        child: Text(
                          _testResult!,
                          style: TextStyle(color: _testOk ? OverlayColors.running : OverlayColors.failed, fontSize: 12),
                        ),
                      ),
                  ],
                ),
                _section('Runs'),
                _field(_experiments, 'Experiments', helper: 'One name per line. Empty: all experiments.', maxLines: 4),
                const SizedBox(height: 10),
                _field(_user, 'Only runs of user', helper: 'The mlflow.user tag. Empty: everyone.'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _field(_epochMetric, 'Epoch metric', helper: 'Current epoch')),
                    const SizedBox(width: 12),
                    Expanded(child: _field(_totalParam, 'Total epochs parameter', helper: 'For the progress bar')),
                  ],
                ),
                const SizedBox(height: 10),
                _field(
                  _stale,
                  'Orange after (minutes)',
                  helper: 'A running run with no new metric for this long',
                  number: true,
                ),
                _section('Overlay'),
                Row(
                  children: [
                    const Text('Opacity'),
                    Expanded(
                      child: Slider(
                        value: _opacity.toDouble(),
                        min: 20,
                        max: 100,
                        divisions: 16,
                        label: '$_opacity %',
                        onChanged: (v) => setState(() => _opacity = v.round()),
                      ),
                    ),
                    SizedBox(width: 44, child: Text('$_opacity %', textAlign: TextAlign.end)),
                  ],
                ),
                _check('Always on top', _onTop, (v) => setState(() => _onTop = v)),
                _check(
                  'Grow automatically with the runs',
                  _autoGrow,
                  (v) => setState(() => _autoGrow = v),
                  subtitle: 'It always shrinks when there are fewer runs',
                ),
                _section('Notifications'),
                _check('When a run fails or is killed', _notifyFailure, (v) => setState(() => _notifyFailure = v)),
                _check('When a run finishes', _notifyFinish, (v) => setState(() => _notifyFinish = v)),
                if (Autostart.isSupported) ...[
                  _section('System'),
                  _check(
                    'Start mlwatcher when I log in',
                    _autostart ?? false,
                    _autostart == null ? null : (v) => setState(() => _autostart = v),
                    subtitle: 'If you move the mlwatcher folder, enable this again',
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => widget.onClose(false), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(fontSize: 11, letterSpacing: 0.8, color: OverlayColors.accent),
    ),
  );

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    String? helper,
    bool obscure = false,
    bool number = false,
    int maxLines = 1,
  }) => TextField(
    controller: c,
    obscureText: obscure,
    maxLines: maxLines,
    minLines: 1,
    keyboardType: number ? TextInputType.number : null,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _check(String label, bool value, ValueChanged<bool>? onChanged, {String? subtitle}) => CheckboxListTile(
    value: value,
    onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
    title: Text(label, style: const TextStyle(fontSize: 13)),
    subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(fontSize: 11)),
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
  );
}
