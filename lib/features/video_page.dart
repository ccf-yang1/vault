import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/browse_providers.dart';
import '../state/session_providers.dart';

/// HTML 04（旧版）：视频播放器。
///
/// 大文件走「流式优先」：AVFoundation 没有带 header 的位置，所以播放地址来自本地
/// 回环代理（[AuthProxy]），由它补 Basic 认证、把 Range 原样转发并回传 Content-Range。
/// 播放器从头分段取，首帧到了就有画面，拖动是一次毫秒级往返（需求 §3.4）。
/// 服务器对 Range 不回 206（能播但拖不动）、或流式半路报错时，自动退回整段下载再本地播。
class VideoPage extends ConsumerStatefulWidget {
  const VideoPage({required this.entry, this.localFile, super.key});

  final RemoteEntry entry;

  /// 压缩包内条目：已经解压到沙盒，直接用本地文件播，不走代理。
  final File? localFile;

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _controlsVisible = true;
  bool _scrubbing = false;
  Duration _dragTarget = Duration.zero;
  Timer? _hideTimer;

  bool _fullscreen = false;
  // 当前画面来源，用于副标题与「流式失败退回下载」的判定。
  _PlayMode _mode = _PlayMode.none;
  // 半路报错自动退回下载只做一次，免得来回重建控制器。
  bool _fallbackTried = false;
  // 画面上横向拖动 seek：按下时记下起点 x 与当前播放位置，按整屏宽度映射到时长。
  // 拖动只覆盖视频层、不含底部进度条 Slider，两者手势不会互相抢（这正是当初去掉
  // 整屏横扫改拖进度条的原因，现在分层就能同时保留）。
  double _dragStartPx = 0;
  Duration _dragAnchor = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 进页面先锁竖屏、恢复常规系统栏；横屏只由全屏按钮或物理转屏触发。
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    // 把方向和系统栏还给 App，其它页不该停在横屏/沉浸式里。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    super.dispose();
  }

  /// 物理转屏（非全屏时锁了竖屏不会触发，这里主要兜全屏左右旋转后的一致性）。
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final landscape = size.width > size.height;
    if (landscape == _fullscreen) return;
    setState(() => _fullscreen = landscape);
    SystemChrome.setEnabledSystemUIMode(landscape ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
        overlays: landscape ? const [] : SystemUiOverlay.values);
  }

  void _toggleFullscreen() {
    final on = !_fullscreen;
    setState(() {
      _fullscreen = on;
      _controlsVisible = true;
    });
    if (on) {
      SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    if (_controller?.value.isPlaying ?? false) _scheduleHide();
  }

  Future<void> _open() async {
    final local = widget.localFile;
    if (local != null) {
      if (await _tryFile(local, _PlayMode.file)) return;
      _fail();
      return;
    }
    // 沙盒里已经有完整文件（之前看过/下过）：直接本地播，不用再走网络。
    final cached = await _cachedFile();
    if (cached != null && await _tryFile(cached, _PlayMode.file)) return;
    // 流式优先：Range 能用就走代理边取边播，几个 G 也是点开就播、抬手就拖。
    if (await _rangeWorks() && await _tryStream()) return;
    // 兜底：服务器忽略 Range（能播但拖不动）或流式起不来，退回整段下载。
    await _downloadAndPlay();
  }

  /// 只查沙盒缓存，不触发下载。
  Future<File?> _cachedFile() async {
    try {
      final key = cacheKeyFor(widget.entry);
      final cache = ref.read(cacheProvider);
      final file = await cache.fileFor(
        bucketForExtension(key.ext),
        remotePath: key.path,
        displayName: key.name,
        etag: key.etag,
        ext: key.ext.startsWith('.') ? key.ext.substring(1) : key.ext,
      );
      if (await file.exists() && await file.length() > 0) {
        await cache.touch(file);
        return file;
      }
      return null;
    } on Object {
      return null;
    }
  }

  Future<bool> _rangeWorks() async {
    try {
      return await ref.read(davProvider).rangeSupported(widget.entry.path);
    } on Object {
      return false;
    }
  }

  Future<bool> _tryStream() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        await ref.read(proxyProvider).urlFor(widget.entry.path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await controller.initialize();
      _adopt(controller, _PlayMode.stream);
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _tryFile(File file, _PlayMode mode) async {
    try {
      final controller = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await controller.initialize();
      _adopt(controller, mode);
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _downloadAndPlay() async {
    if (!mounted) return;
    setState(() => _mode = _PlayMode.download);
    try {
      final file = await ref.read(cachedFileProvider(cacheKeyFor(widget.entry)).future);
      if (await _tryFile(file, _PlayMode.download)) return;
    } on Object {
      // 整段下载也失败，落到下面的错误态。
    }
    _fail();
  }

  void _adopt(VideoPlayerController controller, _PlayMode mode) {
    controller.addListener(_onTick);
    if (!mounted) {
      unawaited(controller.dispose());
      return;
    }
    setState(() {
      _controller = controller;
      _mode = mode;
      _loading = false;
      _error = null;
    });
    _scheduleHide();
  }

  void _fail() {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = _friendly(widget.entry.extension);
    });
  }

  void _retry() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      unawaited(controller.dispose());
    }
    setState(() {
      _controller = null;
      _loading = true;
      _error = null;
      _scrubbing = false;
      _mode = _PlayMode.none;
      _fallbackTried = false;
    });
    unawaited(_open());
  }

  static String _friendly(String ext) => switch (ext) {
        '.mkv' || '.avi' || '.flv' || '.wmv' || '.ts' || '.webm' || '.rmvb' || '.rm' ||
        '.m2ts' || '.vob' || '.mpg' || '.mpeg' || '.mxf' || '.ogv' =>
          'iOS 自带播放器不支持 $ext，换成 MP4 / MOV 再试',
        _ => '视频打不开：流式播放和整段下载都没成功，可能是这个编码 iOS 解不了，或服务器响应异常。可点重试。',
      };

  void _onTick() {
    final controller = _controller;
    if (controller == null) return;
    // 流式半路报错（连接断了、某一段取不到）：自己退回整段下载，不用用户手动重试。
    if (_mode == _PlayMode.stream && controller.value.hasError) {
      if (_fallbackTried) return;
      _fallbackTried = true;
      controller.removeListener(_onTick);
      unawaited(controller.dispose());
      setState(() {
        _controller = null;
        _loading = true;
        _mode = _PlayMode.download;
      });
      unawaited(_downloadAndPlay());
      return;
    }
    if (controller.value.isBuffering) return;
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

  String get _modeLabel => switch (_mode) {
        _PlayMode.stream => '流式播放',
        _PlayMode.download => '下载后播放',
        _ => widget.localFile != null ? '已解压后播放' : '本地缓存播放',
      };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final position = _scrubbing ? _dragTarget : (controller?.value.position ?? Duration.zero);
    final total = controller?.value.duration ?? Duration.zero;
    final progress = total == Duration.zero ? 0.0 : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    // 全屏（横屏）：无 AppBar、无 SafeArea，播放层铺满整屏。
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _player(controller, position, total, progress),
      );
    }

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
                  _loading ? '连接中' : _modeLabel,
                ].whereType<String>().join(' · '),
              ),
              Expanded(child: _player(controller, position, total, progress)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _player(
    VideoPlayerController? controller,
    Duration position,
    Duration total,
    double progress,
  ) {
    if (_loading) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: VaultColors.accent),
              ),
              SizedBox(height: 16),
              Text(
                _mode == _PlayMode.download ? '这个服务器不支持分段播放，正在先下载…' : '正在打开视频…',
                style: TextStyle(fontSize: 13, color: VaultColors.muted),
              ),
            ],
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return ColoredBox(
        color: Colors.black,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const VIcon('video', size: 30, color: Color(0xFF3A3F46)),
                const SizedBox(height: 14),
                Text(
                  _error ?? '无法播放',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
                ),
                const SizedBox(height: 20),
                GhostButton(label: '重 试', onPressed: _retry),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频层：单击切控件，横向拖动 seek。底部进度条 Slider 不在这个手势层里，
        // 所以拖动画面和拖进度条各拿各的手势，不会互相抢。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            _controlsVisible = !_controlsVisible;
            if (_controlsVisible) _scheduleHide();
          }),
          onHorizontalDragStart: (d) => _beginScrub(controller, d.globalPosition.dx),
          onHorizontalDragUpdate: (d) => _moveScrub(total, d.globalPosition.dx),
          onHorizontalDragEnd: (_) => _endScrub(controller),
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0 ? 16 / 9 : controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        if (!controller.value.isPlaying)
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.42),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                ),
                child: const Center(child: VIcon('play', size: 34, color: Colors.white)),
              ),
            ),
          ),
        if (_scrubbing)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.66),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '跳到 ${formatDuration(position)} / ${formatDuration(total)}',
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
          ),
        if (_controlsVisible)
          Positioned(left: 0, right: 0, bottom: 0, child: _controls(position, total, progress, controller)),
        if (_fullscreen && _controlsVisible)
          Positioned(top: 6, left: 6, child: _miniIconButton('back', () => Navigator.of(context).maybePop())),
      ],
    );
  }

  void _beginScrub(VideoPlayerController controller, double startX) {
    if (controller.value.duration == Duration.zero) return;
    _hideTimer?.cancel();
    _dragStartPx = startX;
    _dragAnchor = controller.value.position;
    setState(() {
      _scrubbing = true;
      _dragTarget = controller.value.position;
    });
  }

  void _moveScrub(Duration total, double x) {
    if (!_scrubbing || total == Duration.zero) return;
    final width = MediaQuery.of(context).size.width;
    if (width <= 0) return;
    final dx = x - _dragStartPx;
    var ms = _dragAnchor.inMilliseconds + (dx / width * total.inMilliseconds).round();
    if (ms < 0) ms = 0;
    if (ms > total.inMilliseconds) ms = total.inMilliseconds;
    setState(() => _dragTarget = Duration(milliseconds: ms));
  }

  void _endScrub(VideoPlayerController controller) {
    if (!_scrubbing) return;
    controller.seekTo(_dragTarget);
    setState(() => _scrubbing = false);
    _scheduleHide();
  }

  Widget _controls(Duration position, Duration total, double progress, VideoPlayerController controller) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.82)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(14, 26, 14, _fullscreen ? 16 : 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(formatDuration(position), style: const TextStyle(fontSize: 12, color: Color(0xFFD4D8DE))),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 5,
                    activeTrackColor: VaultColors.accent,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                    thumbColor: Colors.white,
                    overlayColor: VaultColors.accent.withValues(alpha: 0.16),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (value) {
                      if (total == Duration.zero) return;
                      // 拖动过程中别自动收起控制栏。
                      _hideTimer?.cancel();
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
              Text(formatDuration(total), style: const TextStyle(fontSize: 12, color: Color(0xFFD4D8DE))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左右等宽占位，让中间三键保持视觉居中。
              SizedBox(width: 46, child: _miniIconButton(_fullscreen ? 'exitFullscreen' : 'fullscreen', _toggleFullscreen)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _bigBtn('rewind10', () => _skip(-10)),
                  const SizedBox(width: 24),
                  _playBtn(controller),
                  const SizedBox(width: 24),
                  _bigBtn('forward10', () => _skip(10)),
                ],
              ),
              const SizedBox(width: 46),
            ],
          ),
          SizedBox(height: _fullscreen ? 2 : 6),
          Text(
            '拖动画面或进度条可快进 / 快退',
            style: TextStyle(fontSize: 10.5, color: VaultColors.dim),
          ),
        ],
      ),
    );
  }

  /// 快退 / 快进这类次级大按钮：52×52 触控区、图标 26，比原来的 42/19 明显一大圈。
  Widget _bigBtn(String icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Center(child: VIcon(icon, size: 26, color: Colors.white)),
      ),
    );
  }

  Widget _playBtn(VideoPlayerController controller) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlay,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        child: Center(
          child: VIcon(controller.value.isPlaying ? 'pause' : 'play', size: 30, color: Colors.white),
        ),
      ),
    );
  }

  Widget _miniIconButton(String icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 46,
        height: 46,
        child: Center(child: VIcon(icon, size: 22, color: Colors.white)),
      ),
    );
  }
}

/// 画面来源：none 还没起播，stream 走代理流式，file 本地文件（缓存命中或压缩包解压），
/// download 是为兜底刚整段下完的。
enum _PlayMode { none, stream, file, download }
