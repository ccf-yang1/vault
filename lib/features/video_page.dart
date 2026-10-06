import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/session_providers.dart';

/// HTML 04（旧版）：视频播放器。
///
/// WebDAV 需要认证头，AVFoundation 又没法带 header，所以播放地址来自本地回环
/// 代理（[AuthProxy]）；拖进度条依赖 Range，代理会原样转发，因此是「边播边预取」
/// 而不是先下完再播（需求 §3.4）。
class VideoPage extends ConsumerStatefulWidget {
  const VideoPage({required this.entry, this.localFile, super.key});

  final RemoteEntry entry;

  /// 压缩包内条目：已经解压到沙盒，直接用本地文件播，不走代理。
  final File? localFile;

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _controlsVisible = true;
  bool _scrubbing = false;
  Duration _dragTarget = Duration.zero;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final local = widget.localFile;
      final controller = local == null
          ? VideoPlayerController.networkUrl(
              await ref.read(proxyProvider).urlFor(widget.entry.path),
              videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
            )
          : VideoPlayerController.file(
              local,
              videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
            );
      await controller.initialize();
      controller.addListener(_onTick);
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      _scheduleHide();
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(widget.entry.extension);
      });
    }
  }

  static String _friendly(String ext) => switch (ext) {
        '.mkv' || '.avi' || '.flv' || '.wmv' || '.ts' =>
          'iOS 自带播放器不支持 $ext，换成 MP4 / MOV 再试',
        _ => '视频加载失败，可能是网络断开或服务器不允许 Range 请求',
      };

  void _onTick() {
    if (_controller?.value.isBuffering ?? false) return;
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
        _controlsVisible = true;
        _hideTimer?.cancel();
      } else {
        controller.play();
        _scheduleHide();
      }
    });
  }

  void _skip(int seconds) {
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    final target = controller.value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero ? Duration.zero : (target > total ? total : target);
    controller.seekTo(clamped);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!(_controller?.value.isPlaying ?? false)) return;
    _hideTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _onHorizontalDrag(double delta) {
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    if (total == Duration.zero) return;
    // 横扫一整屏 ≈ 快进 60 秒。
    final step = (delta / 320) * 10;
    var next = (_scrubbing ? _dragTarget : controller.value.position) + Duration(seconds: step.round());
    if (next < Duration.zero) next = Duration.zero;
    if (next > total) next = total;
    setState(() {
      _scrubbing = true;
      _dragTarget = next;
      _controlsVisible = true;
    });
  }

  void _endDrag() {
    final controller = _controller;
    if (controller == null || !_scrubbing) return;
    controller.seekTo(_dragTarget);
    setState(() => _scrubbing = false);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final position = _scrubbing ? _dragTarget : (controller?.value.position ?? Duration.zero);
    final total = controller?.value.duration ?? Duration.zero;
    final progress = total == Duration.zero ? 0.0 : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                leading: IconBtn(
                  icon: 'back',
                  color: VaultColors.text,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                title: widget.entry.name,
                subtitle: [
                  widget.entry.size > 0 ? formatBytes(widget.entry.size) : null,
                  _loading ? '连接中' : (widget.localFile == null ? '边播边预取' : '已解压后播放'),
                ].whereType<String>().join(' · '),
              ),
              Expanded(
                child: Center(
                  child: _body(controller, position, total, progress),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    VideoPlayerController? controller,
    Duration position,
    Duration total,
    double progress,
  ) {
    if (_loading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
          ),
          SizedBox(height: 16),
          Text('正在建立带认证的播放通道…', style: TextStyle(fontSize: 12.5, color: VaultColors.muted)),
        ],
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const VIcon('video', size: 30, color: Color(0xFF3A3F46)),
            const SizedBox(height: 14),
            Text(
              _error ?? '无法播放',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
            ),
            const SizedBox(height: 20),
            GhostButton(label: '重 试', onPressed: () => setState(() => _open())),
          ],
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _controlsVisible = !_controlsVisible;
        if (_controlsVisible) _scheduleHide();
      }),
      onHorizontalDragUpdate: (details) => _onHorizontalDrag(details.delta.dx),
      onHorizontalDragEnd: (_) => _endDrag(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio == 0 ? 16 / 9 : controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          if (!controller.value.isPlaying)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.42),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: const Center(child: VIcon('play', size: 26, color: Colors.white)),
              ),
            ),
          if (_controlsVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _controls(position, total, progress, controller),
            ),
        ],
      ),
    );
  }

  Widget _controls(Duration position, Duration total, double progress, VideoPlayerController controller) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.78)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 30, 14, 14),
      child: Column(
        children: [
          if (_scrubbing)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('跳到 ${formatDuration(position)} / ${formatDuration(total)}',
                  style: const TextStyle(fontSize: 11.5, color: VaultColors.accent)),
            ),
          Row(
            children: [
              Text(formatDuration(position), style: const TextStyle(fontSize: 11, color: Color(0xFFB9BEC6))),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    activeTrackColor: VaultColors.accent,
                    inactiveTrackColor: VaultColors.surface2,
                    thumbColor: VaultColors.accent,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (value) {
                      if (total == Duration.zero) return;
                      setState(() {
                        _scrubbing = true;
                        _dragTarget = total * value;
                      });
                    },
                    onChangeEnd: (value) {
                      if (total == Duration.zero) return;
                      controller.seekTo(total * value);
                      setState(() => _scrubbing = false);
                      _scheduleHide();
                    },
                  ),
                ),
              ),
              Text(formatDuration(total), style: const TextStyle(fontSize: 11, color: Color(0xFFB9BEC6))),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconBtn(icon: 'rewind10', color: VaultColors.text, onTap: () => _skip(-10)),
              const SizedBox(width: 10),
              IconBtn(
                icon: controller.value.isPlaying ? 'pause' : 'play',
                color: VaultColors.text,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 10),
              IconBtn(icon: 'forward10', color: VaultColors.text, onTap: () => _skip(10)),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            '左右拖动屏幕可快进 / 快退',
            style: TextStyle(fontSize: 10.5, color: VaultColors.dim),
          ),
        ],
      ),
    );
  }
}
