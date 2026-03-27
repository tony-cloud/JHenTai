import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/database/dao/gallery_history_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/extension/list_extension.dart';
import 'package:jhentai/model/gallery_history_model.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/rpc_service.dart';
import 'package:jhentai/service/storage_service.dart';
import 'package:jhentai/setting/rpc_setting.dart';
import 'package:jhentai/network/rpc_request.dart';

HistoryService historyService = HistoryService();

class HistoryService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String historyUpdateId = 'historyUpdateId';
  static const String _webHistoryStorageKey = 'web_gallery_history_v2';

  static const int pageSize = 100;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      [storageService, rpcSetting, rpcService, rpcRequest];

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  Future<int> getPageCount() async {
    if (_shouldUseRemoteHistoryRead()) {
      try {
        final Map<String, dynamic> result = await rpcRequest.requestHistoryPage(
          pageIndex: 0,
          pageSize: 1,
        );
        final int totalCount = (result['totalCount'] as num?)?.toInt() ?? 0;
        return totalCount == 0 ? 0 : (totalCount - 1) ~/ pageSize + 1;
      } on RPCRequestException catch (e) {
        log.warning('RPC history page count fallback to local: $e');
      } catch (e) {
        log.warning('RPC history page count fallback to local', e, true);
      }
    }

    if (kIsWeb) {
      final int totalCount = (await _readWebHistories()).length;
      return totalCount == 0 ? 0 : (totalCount - 1) ~/ pageSize + 1;
    }

    int totalCount = await GalleryHistoryDao.selectTotalCount();
    return totalCount == 0 ? 0 : (totalCount - 1) ~/ pageSize + 1;
  }

  Future<List<GalleryHistoryModel>> getByPageIndex(int pageIndex) async {
    if (_shouldUseRemoteHistoryRead()) {
      try {
        final Map<String, dynamic> result = await rpcRequest.requestHistoryPage(
          pageIndex: pageIndex,
          pageSize: pageSize,
        );
        final List<dynamic> rawRecords =
            result['records'] is List ? result['records'] as List : const <dynamic>[];

        return rawRecords.whereType<Map>().map((record) {
          final Map<String, dynamic> casted = record.cast<String, dynamic>();
          return GalleryHistoryModel.fromJson(jsonDecode(casted['jsonBody'] as String));
        }).toList(growable: false);
      } on RPCRequestException catch (e) {
        log.warning('RPC history page fallback to local: $e');
      } catch (e) {
        log.warning('RPC history page fallback to local', e, true);
      }
    }

    if (kIsWeb) {
      final List<GalleryHistoryV2Data> histories = await _readWebHistories();
      final int start = pageIndex * pageSize;
      if (start >= histories.length) {
        return <GalleryHistoryModel>[];
      }

      final int end = (start + pageSize) > histories.length ? histories.length : start + pageSize;
      return histories
          .sublist(start, end)
          .map<GalleryHistoryModel>((h) => GalleryHistoryModel.fromJson(jsonDecode(h.jsonBody)))
          .toList();
    }

    List<GalleryHistoryV2Data> historys =
        await GalleryHistoryDao.selectByPageIndex(pageIndex, pageSize);
    return historys
        .map<GalleryHistoryModel>((h) => GalleryHistoryModel.fromJson(jsonDecode(h.jsonBody)))
        .toList();
  }

  Future<List<GalleryHistoryV2Data>> getLatest10000RawHistory() async {
    if (_shouldUseRemoteHistoryRead()) {
      try {
        final Map<String, dynamic> result = await rpcRequest.requestHistoryPage(
          pageIndex: 0,
          pageSize: 10000,
        );
        final List<dynamic> rawRecords =
            result['records'] is List ? result['records'] as List : const <dynamic>[];

        return rawRecords.whereType<Map>().map((record) {
          return GalleryHistoryV2Data.fromJson(record.cast<String, dynamic>());
        }).toList(growable: false);
      } on RPCRequestException catch (e) {
        log.warning('RPC latest history fallback to local: $e');
      } catch (e) {
        log.warning('RPC latest history fallback to local', e, true);
      }
    }

    if (kIsWeb) {
      final List<GalleryHistoryV2Data> histories = await _readWebHistories();
      return histories.length <= 10000 ? histories : histories.sublist(0, 10000);
    }

    return appDb.managers.galleryHistoryV2
        .orderBy((o) => o.lastReadTime.desc() & o.gid.desc())
        .limit(10000)
        .get();
  }

  Future<void> record(GalleryHistoryModel gallery) async {
    log.trace('Record history: ${gallery.galleryUrl.gid}');

    try {
      if (_shouldUseRemoteHistoryWrite()) {
        await rpcRequest.requestRecordHistory(
          gid: gallery.galleryUrl.gid,
          jsonBody: jsonEncode(gallery),
          lastReadTime: DateTime.now().toString(),
        );
        return;
      }

      if (kIsWeb) {
        final List<GalleryHistoryV2Data> histories = await _readWebHistories();
        final GalleryHistoryV2Data newHistory = GalleryHistoryV2Data(
          gid: gallery.galleryUrl.gid,
          jsonBody: jsonEncode(gallery),
          lastReadTime: DateTime.now().toString(),
        );
        histories.removeWhere((history) => history.gid == newHistory.gid);
        histories.add(newHistory);
        await _writeWebHistories(histories);
        return;
      }

      await GalleryHistoryDao.replaceHistory(
        GalleryHistoryV2Data(
          gid: gallery.galleryUrl.gid,
          jsonBody: jsonEncode(gallery),
          lastReadTime: DateTime.now().toString(),
        ),
      );
    } on RPCRequestException catch (e) {
      log.warning('RPC record history fallback to local: $e');
      await _recordLocal(gallery);
    } on Exception catch (e) {
      log.error('Record history failed!', e);
    }
  }

  Future<void> batchRecord(List<GalleryHistoryV2Data> gallerys) async {
    log.trace('Batch record history, size: ${gallerys.length}');

    try {
      if (_shouldUseRemoteHistoryWrite()) {
        for (final GalleryHistoryV2Data history in gallerys) {
          await rpcRequest.requestRecordHistory(
            gid: history.gid,
            jsonBody: history.jsonBody,
            lastReadTime: history.lastReadTime,
          );
        }
        return;
      }

      if (kIsWeb) {
        final Map<int, GalleryHistoryV2Data> merged = {
          for (final GalleryHistoryV2Data history in await _readWebHistories())
            history.gid: history,
        };
        for (final GalleryHistoryV2Data history in gallerys) {
          merged[history.gid] = history;
        }
        await _writeWebHistories(merged.values.toList());
        return;
      }

      for (List<GalleryHistoryV2Data> partition in gallerys.partition(2000)) {
        await GalleryHistoryDao.batchReplaceHistory(partition);
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } on RPCRequestException catch (e) {
      log.warning('RPC batch record history fallback to local: $e');
      await _batchRecordLocal(gallerys);
    } on Exception catch (e) {
      log.error('Record history failed!', e);
    }
  }

  Future<bool> delete(int gid) async {
    log.info('Delete history: $gid');

    if (_shouldUseRemoteHistoryWrite()) {
      try {
        final Map<String, dynamic> result = await rpcRequest.requestDeleteHistory(gid: gid);
        return result['deleted'] == true;
      } on RPCRequestException catch (e) {
        log.warning('RPC delete history fallback to local: $e');
      } catch (e) {
        log.warning('RPC delete history fallback to local', e, true);
      }
    }

    if (kIsWeb) {
      final List<GalleryHistoryV2Data> histories = await _readWebHistories();
      final int before = histories.length;
      histories.removeWhere((history) => history.gid == gid);
      await _writeWebHistories(histories);
      return histories.length != before;
    }

    return await GalleryHistoryDao.deleteHistory(gid) > 0;
  }

  Future<bool> deleteAll() async {
    log.info('Delete all historys');

    if (_shouldUseRemoteHistoryWrite()) {
      try {
        await rpcRequest.requestDeleteAllHistory();
        return true;
      } on RPCRequestException catch (e) {
        log.warning('RPC delete all history fallback to local: $e');
      } catch (e) {
        log.warning('RPC delete all history fallback to local', e, true);
      }
    }

    if (kIsWeb) {
      await storageService.remove(_webHistoryStorageKey);
      return true;
    }

    return await GalleryHistoryDao.deleteAllHistory() > 0;
  }

  Future<List<GalleryHistoryV2Data>> _readWebHistories() async {
    final List<dynamic>? rawHistories = storageService.read<List<dynamic>>(_webHistoryStorageKey);
    if (rawHistories == null) {
      return <GalleryHistoryV2Data>[];
    }

    final List<GalleryHistoryV2Data> histories = rawHistories
        .whereType<Map>()
        .map((rawHistory) => rawHistory.map((key, value) => MapEntry(key.toString(), value)))
        .map(
          (rawHistory) => GalleryHistoryV2Data(
            gid: rawHistory['gid'] as int,
            jsonBody: rawHistory['jsonBody'] as String,
            lastReadTime: rawHistory['lastReadTime'] as String,
          ),
        )
        .toList();

    histories.sort((a, b) {
      final int timeCompare = b.lastReadTime.compareTo(a.lastReadTime);
      return timeCompare != 0 ? timeCompare : b.gid.compareTo(a.gid);
    });

    return histories;
  }

  Future<void> _writeWebHistories(List<GalleryHistoryV2Data> histories) async {
    histories.sort((a, b) {
      final int timeCompare = b.lastReadTime.compareTo(a.lastReadTime);
      return timeCompare != 0 ? timeCompare : b.gid.compareTo(a.gid);
    });

    await storageService.write(
      _webHistoryStorageKey,
      histories
          .map((history) => {
                'gid': history.gid,
                'jsonBody': history.jsonBody,
                'lastReadTime': history.lastReadTime,
              })
          .toList(),
    );
  }

  bool _shouldUseRemoteHistoryRead() {
    if (!rpcSetting.enableRpcMode.value) {
      return false;
    }

    if (rpcService.capabilities.isEmpty) {
      return true;
    }

    return rpcService.supportsCapability(RPCCapabilities.historyRead);
  }

  bool _shouldUseRemoteHistoryWrite() {
    if (!rpcSetting.enableRpcMode.value) {
      return false;
    }

    if (rpcService.capabilities.isEmpty) {
      return true;
    }

    return rpcService.supportsCapability(RPCCapabilities.historyWrite);
  }

  Future<void> _recordLocal(GalleryHistoryModel gallery) async {
    if (kIsWeb) {
      final List<GalleryHistoryV2Data> histories = await _readWebHistories();
      final GalleryHistoryV2Data newHistory = GalleryHistoryV2Data(
        gid: gallery.galleryUrl.gid,
        jsonBody: jsonEncode(gallery),
        lastReadTime: DateTime.now().toString(),
      );
      histories.removeWhere((history) => history.gid == newHistory.gid);
      histories.add(newHistory);
      await _writeWebHistories(histories);
      return;
    }

    await GalleryHistoryDao.replaceHistory(
      GalleryHistoryV2Data(
        gid: gallery.galleryUrl.gid,
        jsonBody: jsonEncode(gallery),
        lastReadTime: DateTime.now().toString(),
      ),
    );
  }

  Future<void> _batchRecordLocal(List<GalleryHistoryV2Data> gallerys) async {
    if (kIsWeb) {
      final Map<int, GalleryHistoryV2Data> merged = {
        for (final GalleryHistoryV2Data history in await _readWebHistories()) history.gid: history,
      };
      for (final GalleryHistoryV2Data history in gallerys) {
        merged[history.gid] = history;
      }
      await _writeWebHistories(merged.values.toList());
      return;
    }

    for (List<GalleryHistoryV2Data> partition in gallerys.partition(2000)) {
      await GalleryHistoryDao.batchReplaceHistory(partition);
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
