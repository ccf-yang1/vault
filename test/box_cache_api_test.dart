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

  group('落点候选：账号隔离 + 隐私优先', () {
    const both = ['local', 'common'];

    test('连 :5244 只给 local，不列出别的账号的落点', () {
      expect(cacheTargetsFor(instance: BoxInstance.priv, available: both), ['local']);
      expect(cacheTargetsFor(instance: BoxInstance.priv, available: ['common', 'local']), ['local']);
    });

    test('连 :15244 只给 common，永远不列 local', () {
      expect(cacheTargetsFor(instance: BoxInstance.family, available: both), ['common']);
    });

    test('这个账号对应的落点盒子上没配时不给候选，而不是塞一个别的盘的', () {
      expect(cacheTargetsFor(instance: BoxInstance.priv, available: ['media', 'common']), isEmpty);
      expect(cacheTargetsFor(instance: BoxInstance.family, available: ['local']), isEmpty);
    });

    test('端口认不出来就照盒子给的列（没法判断归属，不替用户猜）', () {
      expect(cacheTargetsFor(instance: BoxInstance.unknown, available: both), both);
      expect(cacheTargetsFor(instance: BoxInstance.unknown, available: ['media']), ['media']);
    });

    test('端口映射到实例：5244 私人、15244 家庭、其它认不出', () {
      expect(BoxInstance.fromPort(5244), BoxInstance.priv);
      expect(BoxInstance.fromPort(15244), BoxInstance.family);
      expect(BoxInstance.fromPort(80), BoxInstance.unknown);
      expect(BoxInstance.fromPort(null), BoxInstance.unknown);
    });

    test('local 被藏起来就不点名 —— 隐藏模式开着，或它自己在隐藏目录里', () {
      expect(cacheTargetIsQuiet(to: 'local', hiddenMode: true, targetHidden: false), isTrue);
      expect(cacheTargetIsQuiet(to: 'local', hiddenMode: false, targetHidden: true), isTrue);
      expect(cacheTargetIsQuiet(to: 'local', hiddenMode: true, targetHidden: true), isTrue);
      expect(cacheTargetIsQuiet(to: 'local', hiddenMode: false, targetHidden: false), isFalse);
    });

    test('家庭那份是共用的，任何时候都照常点名', () {
      expect(cacheTargetIsQuiet(to: 'common', hiddenMode: true, targetHidden: true), isFalse);
      expect(cacheTargetIsQuiet(to: 'media', hiddenMode: true, targetHidden: true), isFalse);
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
