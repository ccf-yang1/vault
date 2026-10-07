import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/box_cache_api.dart';

void main() {
  group('cacheSrcFor：剥掉第一层云盘挂载目录', () {
    test('/aliyun/来自分享/高中 → 来自分享/高中', () {
      expect(cacheSrcFor('/aliyun/来自分享/高中'), '来自分享/高中');
    });

    test('接口不收前导斜杠', () {
      expect(cacheSrcFor('/aliyun/IPA'), 'IPA');
    });

    test('只剩一层时给不出 src，返回 null', () {
      expect(cacheSrcFor('/aliyun'), isNull);
      expect(cacheSrcFor('/'), isNull);
    });

    test('超过 300 字符会被接口拒掉，提前返回 null', () {
      final long = '/dav/${'a' * 301}';
      expect(cacheSrcFor(long), isNull);
    });
  });

  group('cacheSubFor：本地缓存目录名', () {
    test('斜杠换成 __，避免两个同名末级目录撞到同一个 dest', () {
      expect(cacheSubFor('来自分享/高中'), '来自分享__高中');
      expect(cacheSubFor('a/b/高中'), 'a__b__高中');
    });

    test('接口禁止的字符替成下划线', () {
      expect(cacheSubFor(r"来自分享/带'引号"), '来自分享__带_引号');
    });

    test('结尾斜杠不产生多余下划线', () {
      expect(cacheSubFor('来自分享/高中/'), '来自分享__高中');
    });
  });

  group('deriveBaseUrl：从 WebDAV 地址推盒子缓存服务', () {
    test('同主机换端口和前缀，不带多余的查询串', () {
      expect(
        BoxCacheApi.deriveBaseUrl('http://192.168.1.17:5244/dav'),
        'http://192.168.1.17:9000/api/cache',
      );
    });

    test('地址不成形时返回 null', () {
      expect(BoxCacheApi.deriveBaseUrl(''), isNull);
      expect(BoxCacheApi.deriveBaseUrl('192.168.1.17:5244/dav'), isNull);
    });
  });

  group('落点候选：隐私优先', () {
    const both = ['local', 'common'];

    test('家庭实例（:15244）永远不列 local', () {
      expect(
        cacheTargetsFor(instance: BoxInstance.family, hiddenMode: false, available: both),
        ['common'],
      );
      expect(
        cacheTargetsFor(instance: BoxInstance.family, hiddenMode: true, available: both),
        ['common'],
      );
    });

    test('私人实例开着隐藏模式时不给选，直接用 local', () {
      expect(
        cacheTargetsFor(instance: BoxInstance.priv, hiddenMode: true, available: both),
        ['local'],
      );
    });

    test('私人实例没开隐藏模式时两个都列出来', () {
      expect(
        cacheTargetsFor(instance: BoxInstance.priv, hiddenMode: false, available: both),
        both,
      );
    });

    test('端口认不出来就照盒子给的列（隐藏模式也不吞落点）', () {
      expect(
        cacheTargetsFor(instance: BoxInstance.unknown, hiddenMode: true, available: ['media']),
        ['media'],
      );
    });

    test('盒子给的落点里没有 local 时，隐私模式退回列出的第一个', () {
      expect(
        cacheTargetsFor(instance: BoxInstance.priv, hiddenMode: true, available: ['media', 'common']),
        ['media'],
      );
    });

    test('端口映射到实例：5244 私人、15244 家庭、其它认不出', () {
      expect(BoxInstance.fromPort(5244), BoxInstance.priv);
      expect(BoxInstance.fromPort(15244), BoxInstance.family);
      expect(BoxInstance.fromPort(80), BoxInstance.unknown);
      expect(BoxInstance.fromPort(null), BoxInstance.unknown);
    });

    test('落点显示名不出现「私人」', () {
      expect(cacheTargetLabel('local'), '盒子盘');
      expect(cacheTargetLabel('common'), '家庭盘');
      expect(cacheTargetLabel('media'), 'media');
    });
  });

  group('任务解析：字段全部按可缺失处理', () {
    test('进度字段一个都没给也不崩，state 照常解析', () {
      final task = CacheTask.fromJson({
        'id': 't1',
        'src': '来自分享/高中',
        'sub': '来自分享__高中',
        'to': 'local',
        'dest': '/data/cache/local/来自分享__高中',
        'state': 'queued',
      });
      expect(task.state, CacheState.queued);
      expect(task.state.isActive, isTrue);
      expect(task.pct, isNull);
      expect(task.etaS, isNull);
      // GET /tasks/{id} 没有这两个字段。
      expect(task.webUrl, isNull);
    });

    test('盒子认识的新状态之外按失败显示，不抛', () {
      expect(CacheState.parse('paused'), CacheState.failed);
      expect(CacheState.parse(null), CacheState.failed);
    });

    test('记录存盘再读回来不丢字段，null 不写进 JSON', () {
      final record = CacheTaskRecord.fromTask(CacheTask.fromJson({
        'id': 't2',
        'src': '来自分享/高中',
        'sub': '来自分享__高中',
        'to': 'local',
        'dest': '/data/cache/local/来自分享__高中',
        'state': 'running',
        'pct': 42.5,
        'done_bytes': 1000,
        'total_bytes': 2000,
        'web_url': 'http://192.168.1.17:5244/dav/local/来自分享__高中',
      }));
      final json = record.toJson();
      expect(json.containsKey('eta_s'), isFalse);
      expect(json['name'], isNull);

      final back = CacheTaskRecord.fromJson(json);
      expect(back.id, 't2');
      expect(back.state, CacheState.running);
      expect(back.pct, 42.5);
      expect(back.doneBytes, 1000);
      expect(back.webUrl, contains('来自分享__高中'));
      expect(back.name, '高中');
    });

    test('再查一次时接口没回 URL，就沿用记录里那份', () {
      final record = CacheTaskRecord.fromTask(CacheTask.fromJson({
        'id': 't3',
        'src': 'a/b',
        'sub': 'a__b',
        'to': 'local',
        'dest': '/x',
        'state': 'running',
        'web_url': 'http://192.168.1.17:5244/dav/local/a__b',
      }));
      final later = record.withTask(CacheTask.fromJson({
        'id': 't3',
        'src': 'a/b',
        'sub': 'a__b',
        'to': 'local',
        'dest': '/x',
        'state': 'done',
        'pct': 100,
      }));
      expect(later.state, CacheState.done);
      expect(later.webUrl, record.webUrl);
      expect(later.pct, 100);
    });
  });

  group('错误体翻译成人话', () {
    test('服务端给了 message 就用它', () {
      expect(BoxCacheError(400, 'bad_src', '目录名不合法').humanMessage, '目录名不合法');
    });

    test('客户端超时不能算失败，要给出「再点一次会自动跟踪」的出路', () {
      expect(BoxCacheError(0, 'client_timeout', '').humanMessage, contains('再点一次「下载到盒子」'));
    });
  });
}
