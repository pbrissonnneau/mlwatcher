import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

import '../app/watcher_service.dart';
import '../domain/watched_run.dart';
import '../mlflow/mlflow_models.dart';
import 'format.dart';
import 'theme.dart';

/// The compact overlay: a header (drag to move, pin, hide) and one line per run.
///
/// Reports through [onContentHeight] the window height that fits its content:
/// every run up to `maxVisibleRuns` lines, beyond which the list scrolls.
class OverlayView extends StatelessWidget {
  const OverlayView({
    super.key,
    required this.service,
    required this.onToggleOnTop,
    required this.onHide,
    required this.onOpenSettings,
    this.onContentHeight,
    this.resizable = true,
  });

  final WatcherService service;
  final VoidCallback onToggleOnTop;
  final VoidCallback onHide;
  final VoidCallback onOpenSettings;

  /// Called with the height the window needs, whenever it changes.
  final ValueChanged<double>? onContentHeight;

  static const _headerHeight = 20.0;
  static const _listPadding = 2.0;

  /// False in tests (no native window).
  final bool resizable;

  @override
  Widget build(BuildContext context) {
    final content = Material(
      color: OverlayColors.background,
      child: ListenableBuilder(
        listenable: service,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onTop: service.settings.alwaysOnTop, onToggleOnTop: onToggleOnTop, onHide: onHide),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
    return resizable ? DragToResizeArea(resizeEdgeSize: 5, child: content) : content;
  }

  void _reportBody(double height) => onContentHeight?.call(_headerHeight + height);

  Widget _message(_Message message) => SingleChildScrollView(
    child: _HeightReporter(onHeight: _reportBody, child: message),
  );

  Widget _body(BuildContext context) {
    if (!service.settings.isConfigured) {
      return _message(
        _Message(
          icon: Icons.settings,
          text: 'Set the MLflow server in Settings',
          color: OverlayColors.dim,
          onTap: onOpenSettings,
        ),
      );
    }
    if (service.error case final error?) {
      return _message(_Message(icon: Icons.warning_amber_rounded, text: error, color: OverlayColors.failed));
    }
    if (service.loading) return _message(const _Message(text: 'Connecting…', color: OverlayColors.dim));
    final runs = service.runs;
    if (runs.isEmpty) return _message(const _Message(text: 'No runs', color: OverlayColors.dim));
    final now = DateTime.now();
    Widget row(WatchedRun run) => RunRow(
      run: run,
      indicator: run.indicator(now, service.staleAfter),
      now: now,
      onOpen: () => service.openRun(run),
      onDismiss: () => service.dismiss(run.id),
    );
    // Only the first lines are measured: the window fits them, the rest scrolls.
    final fitted = min(runs.length, service.settings.maxVisibleRuns);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: _listPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeightReporter(
            onHeight: (h) => _reportBody(h + 2 * _listPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final run in runs.take(fitted)) row(run)],
            ),
          ),
          for (final run in runs.skip(fitted)) row(run),
        ],
      ),
    );
  }
}

/// Calls [onHeight] after a layout that changed its child's height.
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightReporter renderObject) => renderObject.onHeight = onHeight;
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Resizing the window during layout would re-enter it.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onTop, required this.onToggleOnTop, required this.onHide});

  final bool onTop;
  final VoidCallback onToggleOnTop;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback onPressed, {Color? color}) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(width: 22, height: 20, child: Icon(icon, size: 13, color: color ?? OverlayColors.dim)),
      ),
    );
    return Container(
      height: OverlayView._headerHeight,
      color: OverlayColors.header,
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(left: 7),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'mlwatcher',
                    style: TextStyle(fontSize: 10, color: OverlayColors.dim, letterSpacing: 0.4),
                  ),
                ),
              ),
            ),
          ),
          button(
            onTop ? Icons.push_pin : Icons.push_pin_outlined,
            onTop ? 'Always on top: on' : 'Always on top: off',
            onToggleOnTop,
            color: onTop ? OverlayColors.accent : null,
          ),
          button(Icons.remove, 'Hide (the icon in the notification area brings it back)', onHide),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color, this.icon, this.onTap});

  final String text;
  final Color color;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 5)],
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 11, color: color),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One run: status dot, name, epoch, and a thin progress bar underneath.
/// Click opens the run in MLflow; right-click offers *Dismiss*.
class RunRow extends StatelessWidget {
  const RunRow({
    super.key,
    required this.run,
    required this.indicator,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  final WatchedRun run;
  final RunIndicator indicator;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  Color get color => switch (indicator) {
    RunIndicator.running => OverlayColors.running,
    RunIndicator.stale => OverlayColors.stale,
    RunIndicator.finished => OverlayColors.finished,
    RunIndicator.failed => OverlayColors.failed,
  };

  String get _statusText => switch (indicator) {
    RunIndicator.running => 'Running',
    RunIndicator.stale =>
      'Running, no update for ${formatDuration(now.difference(DateTime.fromMillisecondsSinceEpoch(run.lastSeenAlive)))}',
    RunIndicator.finished => 'Finished',
    RunIndicator.failed => run.status == MlflowStatus.killed ? 'Killed' : 'Failed',
  };

  String get _epochText {
    final e = run.epoch, t = run.totalEpochs;
    if (e == null) return '';
    return t == null ? formatNumber(e) : '${formatNumber(e)}/${formatNumber(t)}';
  }

  @override
  Widget build(BuildContext context) {
    final progress = run.progress;
    final tooltip = [
      run.name,
      'Experiment: ${run.experimentName.isEmpty ? run.experimentId : run.experimentName}',
      '$_statusText · ${formatDuration(run.duration(now))}',
    ].join('\n');
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _showMenu(context, d.globalPosition),
        child: InkWell(
          onTap: onOpen,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 3, 7, 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (indicator == RunIndicator.finished)
                      Icon(Icons.check, size: 10, color: color)
                    else
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        run.name,
                        style: const TextStyle(fontSize: 11.5, color: OverlayColors.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_epochText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        _epochText,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: OverlayColors.dim,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 2.5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      color: color,
                      backgroundColor: OverlayColors.track,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          value: 'dismiss',
          height: 28,
          child: Text('Dismiss', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
    if (choice == 'dismiss') onDismiss();
  }
}
