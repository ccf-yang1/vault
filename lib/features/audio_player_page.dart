import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/browse_providers.dart';

/// 音频播放器（需求：类似播客/课程音频的深蓝极简 UI）。
///
/// iOS 原生解码器放不了 .wma/.asf/.aiff，这类进来直接提示不支持、不初始化播放器。
/// 其余格式先下载缓存到沙盒再本地播，seek 才稳（云盘代理的 Range 不一定可用）。
class AudioPlayerPage extends ConsumerStatefulWidget {
  const AudioPlayerPage({
    required this.playlist,
    required this.initialIndex,
    super.key,
  });

  final List<RemoteEntry> playlist;
  final int initialIndex;

  @override
  ConsumerState<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends ConsumerState<AudioPlayerPage> {
  static const _bgTop = Color(0xFF10233A);
  static const _bgBottom = Color(0xFF0C1620);
  static const _accentSoft = Color(0xFF7FA6E0);

  late final List<RemoteEntry> _order;
  late int _index;
  final AudioPlayer _player = AudioPlayer();

  bool _loading = false;
  String? _error;
  bool _scrubbing = false;
  Duration _dragTarget = Duration.zero;
  bool _shuffle = false;
  _Repeat _repeat = _Repeat.all;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    // 队列里只放 iOS 能放的；不可播项留在原列表里但点进去会提示，这里跳过初始化。
    _order = List.of(widget.playlist);
    _index = widget.initialIndex.clamp(0, _order.length - 1);
    _configureSession();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openCurrent());
  }

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } on Object {
      // 音频会话配置失败不致命，继续。
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  RemoteEntry get _current => _order[_index];

  void _listenOnce() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _positionSub = _player.positionStream.listen((_) {
      if (mounted && !_scrubbing) setState(() {});
    });
    _durationSub = _player.durationStream.listen((_) {
      if (mounted) setState(() {});
    });
    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {});
      if (state.processingState == ProcessingState.completed) _onTrackFinished();
    });
  }

  Future<void> _openCurrent() async {
    final entry = _current;
    if (entry.isIosUnsupportedAudio) {
      setState(() {
        _loading = false;
        _error = 'iOS 自带播放器不支持 ${entry.extension}，请转成 MP3 / M4A / AAC 后再试';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await ref.read(cachedFileProvider(cacheKeyFor(entry)).future);
      await _player.setAudioSource(AudioSource.file(file.path), initialPosition: Duration.zero);
      _listenOnce();
      if (!mounted) return;
      setState(() => _loading = false);
      await _player.play();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(entry.extension, e);
      });
    }
  }

  static String _friendly(String ext, Object e) => switch (ext) {
        '.wma' || '.asf' || '.aiff' || '.aif' || '.ra' || '.rm' =>
          'iOS 自带播放器不支持 $ext，请转成 MP3 / M4A / AAC 后再试',
        _ => '音频加载失败：$e',
      };

  void _onTrackFinished() {
    if (_repeat == _Repeat.one) {
      unawaited(_player.seek(Duration.zero).then((_) => _player.play()));
      return;
    }
    _step(1);
  }

  void _step(int delta) {
    if (_order.isEmpty) return;
    if (_shuffle && delta != 0) {
      _goTo(_randomOther());
      return;
    }
    var next = _index + delta;
    if (next < 0) next = _repeat == _Repeat.all ? _order.length - 1 : 0;
    if (next >= _order.length) {
      if (_repeat == _Repeat.all) {
        next = 0;
      } else {
        unawaited(_player.pause());
        return;
      }
    }
    _goTo(next);
  }

  int _randomOther() {
    if (_order.length <= 1) return _index;
    var r = _index;
    while (r == _index) {
      r = DateTime.now().microsecondsSinceEpoch % _order.length;
    }
    return r;
  }

  void _goTo(int index) {
    if (index < 0 || index >= _order.length) return;
    setState(() {
      _index = index;
      _scrubbing = false;
      _dragTarget = Duration.zero;
    });
    unawaited(_openCurrent());
  }

  void _togglePlay() {
    if (_error != null) {
      unawaited(_openCurrent());
      return;
    }
    if (_player.playing) {
      unawaited(_player.pause());
    } else {
      unawaited(_player.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _current;
    return VaultAnnotatedRegion(
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_bgTop, _bgBottom],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
                  child: Row(
                    children: [
                      IconBtn(icon: 'back', color: Colors.white, onTap: () => Navigator.of(context).maybePop()),
                      Expanded(
                        child: Text(entry.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5, color: Color(0xFFC7D2E4))),
                      ),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
                Expanded(child: _coverAndInfo(entry)),
                _controls(entry),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverAndInfo(RemoteEntry entry) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44),
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1A2740), Color(0xFF141C2B)],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: _error != null
                      ? const VIcon('audio', size: 60, color: Color(0xFF4A556B))
                      : _loading
                          ? const SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: _accentSoft),
                            )
                          : Text(
                              'Audio',
                              style: TextStyle(
                                fontSize: 46,
                                fontStyle: FontStyle.italic,
                                fontWeight: FontWeight.w700,
                                color: _accentSoft,
                                shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 3))],
                              ),
                            ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 4),
          child: Column(
            children: [
              Text(
                _trackTitle(entry),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: Colors.white, height: 1.35),
              ),
              const SizedBox(height: 6),
              Text(
                _error != null ? _artist(entry) : '未知艺术家 · ${RemotePath.parent(entry.path)}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF8296B4), height: 1.4),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFFE0736A), height: 1.5),
            ),
          ),
      ],
    );
  }

  Widget _controls(RemoteEntry entry) {
    final duration = _player.duration ?? Duration.zero;
    final position = _scrubbing ? _dragTarget : _player.position;
    final progress = duration == Duration.zero ? 0.0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(width: 46, child: Text(formatDuration(position), style: const TextStyle(fontSize: 11.5, color: Color(0xFF8296B4), fontFeatures: [FontFeature.tabularFigures()]))),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: _accentSoft,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
                    thumbColor: _accentSoft,
                    overlayColor: _accentSoft.withValues(alpha: 0.14),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: duration == Duration.zero
                        ? null
                        : (v) {
                            setState(() {
                              _scrubbing = true;
                              _dragTarget = duration * v;
                            });
                          },
                    onChangeEnd: duration == Duration.zero
                        ? null
                        : (v) {
                            unawaited(_player.seek(duration * v));
                            setState(() => _scrubbing = false);
                          },
                  ),
                ),
              ),
              SizedBox(
                width: 46,
                child: Text('-${formatDuration(duration - position)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11.5, color: Color(0xFF8296B4), fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _roundIcon('shuffle', active: _shuffle, onTap: () => setState(() => _shuffle = !_shuffle)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _repeat = _repeat.next()),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _repeat == _Repeat.none ? Colors.white.withValues(alpha: 0.06) : _accentSoft.withValues(alpha: 0.22),
                  ),
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VIcon('repeat', size: 22, color: _repeat == _Repeat.none ? const Color(0xFF9FB0C9) : _accentSoft),
                        if (_repeat == _Repeat.one)
                          const Positioned(bottom: 3, right: 6, child: Text('1', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFF7FA6E0)))),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _bigPlay(playing: _player.playing),
              const SizedBox(width: 12),
              IconBtn(icon: 'forward10', color: Colors.white, onTap: () => _step(1)),
              IconBtn(icon: 'queue', color: Colors.white, onTap: () => _openQueue()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bigPlay({required bool playing}) {
    return GestureDetector(
      onTap: _togglePlay,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: Center(child: VIcon(playing ? 'pause' : 'play', size: 28, color: const Color(0xFF0E1A2C))),
      ),
    );
  }

  Widget _roundIcon(String icon, {required bool active, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? _accentSoft.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.06),
        ),
        child: Center(child: VIcon(icon, size: 19, color: active ? _accentSoft : const Color(0xFF9FB0C9))),
      ),
    );
  }

  String _trackTitle(RemoteEntry entry) {
    final dot = entry.name.lastIndexOf('.');
    return dot <= 0 ? entry.name : entry.name.substring(0, dot);
  }

  String _artist(RemoteEntry entry) => '未知艺术家';

  Future<void> _openQueue() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _QueueSheet(order: _order, index: _index, repeat: _repeat, shuffle: _shuffle),
    );
    if (picked != null) _goTo(picked);
  }
}

enum _Repeat { none, all, one }

extension _RepeatCycle on _Repeat {
  _Repeat next() => switch (this) {
        _Repeat.none => _Repeat.all,
        _Repeat.all => _Repeat.one,
        _Repeat.one => _Repeat.none,
      };
}

/// 图二：接下来播放队列。可拖拽排序，点某项直接播放，顶部三个圆钮控随机/循环。
class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet({
    required this.order,
    required this.index,
    required this.repeat,
    required this.shuffle,
  });

  final List<RemoteEntry> order;
  final int index;
  final _Repeat repeat;
  final bool shuffle;

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  late final List<RemoteEntry> _items;
  late int _current;
  late _Repeat _repeat;
  late bool _shuffle;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.order);
    _current = widget.index;
    _repeat = widget.repeat;
    _shuffle = widget.shuffle;
  }

  @override
  Widget build(BuildContext context) {
    final entry = _items[_current.clamp(0, _items.length - 1)];
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Container(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF13233B), Color(0xFF0C1620)]),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: Text('A', style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w700, fontSize: 18, color: Color(0xFF7FA6E0))),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: Colors.white)),
                        const SizedBox(height: 2),
                        const Text('未知艺术家', style: TextStyle(fontSize: 11.5, color: Color(0xFF8296B4))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Row(
                children: [
                  const Text('接下来播放', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                  const Spacer(),
                  _miniToggle('shuffle', active: _shuffle, onTap: () => setState(() => _shuffle = !_shuffle)),
                  const SizedBox(width: 8),
                  _miniToggle('repeat', active: _repeat != _Repeat.none, onTap: () => setState(() => _repeat = _repeat.next())),
                  const SizedBox(width: 8),
                  _miniToggle('sort', active: false),
                ],
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: controller,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: _items.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    final cur = _items[_current];
                    var target = newIndex;
                    if (target > oldIndex) target--;
                    final moved = _items.removeAt(oldIndex);
                    _items.insert(target, moved);
                    _current = _items.indexOf(cur);
                  });
                },
                itemBuilder: (context, i) {
                  final item = _items[i];
                  final isCurrent = i == _current;
                  return ListTile(
                    key: ValueKey(item.path),
                    onTap: () => Navigator.of(context).pop(i),
                    leading: SizedBox(
                      width: 34,
                      height: 34,
                      child: DecoratedBox(
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), gradient: const LinearGradient(colors: [Color(0xFF1A2740), Color(0xFF141C2B)])),
                        child: const Center(child: Text('A', style: TextStyle(fontStyle: FontStyle.italic, color: Color(0xFF7FA6E0), fontWeight: FontWeight.w700))),
                      ),
                    ),
                    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: isCurrent ? const Color(0xFF7FA6E0) : Colors.white)),
                    subtitle: const Text('未知艺术家', style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7C96))),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                        child: VIcon('drag', size: 18, color: Color(0xFF4A556B)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniToggle(String icon, {required bool active, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? const Color(0x337FA6E0) : Colors.white.withValues(alpha: 0.06),
        ),
        child: Center(child: VIcon(icon, size: 17, color: active ? const Color(0xFF7FA6E0) : const Color(0xFF9FB0C9))),
      ),
    );
  }
}
