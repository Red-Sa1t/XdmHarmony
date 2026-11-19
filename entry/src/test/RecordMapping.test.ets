/*
 * U1.1 本地单测：表结构映射/状态计算纯函数用例 13 条（设计书 §7-[A]-3 用例清单）。
 * 被测模块 RecordMapping.ets 零 @kit import、不 import @Observed 类——本地测试环境可直接加载。
 * 覆盖：22 列 INSERT 投影默认值、auth/proxy 透传、读回强制规则（含 roundTrip 的纯函数级证明：
 * status=Waiting(3) 的记录经 rowFromRecord→recordFromRow 后 status==1——"重启读回强制 Stopped"）、
 * computeProgress 截断与零保护、computeInitialStatus、joinTempDir、UpdateEntryRow 15 列形状。
 * 诚实注记（沿用 U0.2）：本会话未运行本地单测执行器；用例照常入库，由 IDE/hvigor LocalUnit
 * 实跑或待 U2.3 统一回归。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  computeInitialStatus,
  computeProgress,
  joinTempDir,
  recordFromRow,
  rowFromRecord,
  updateEntryRowFromRecord,
  DownloadRow,
  UpdateEntryRow
} from '../main/ets/core/db/RecordMapping';
import { AuthenticationInfo, DownloadKind, DownloadStatus, ProxyInfo, ProxyType, RecordData } from '../main/ets/model/DownloadTypes';

/** 缺省 ProxyInfo（System/0/null×3） */
function defaultProxy(): ProxyInfo {
  const proxy: ProxyInfo = {
    proxyType: ProxyType.System,
    host: null,
    port: 0,
    userName: null,
    password: null
  };
  return proxy;
}

/** add 形状的 RecordData（status 由入参给） */
function addShapeRecord(status: number): RecordData {
  const data: RecordData = {
    id: 'test-id',
    kind: DownloadKind.InProgress,
    name: 'file.bin',
    dateAdded: 1727500000000,
    size: 1000,
    status: status,
    progress: 0,
    downloadType: 'application/octet-stream',
    fileNameFetchMode: 0,
    maxSpeedLimitInKiB: 0,
    targetDir: '/data/dir',
    primaryUrl: 'http://probe.local/f.bin',
    refererUrl: null,
    authentication: null,
    proxy: defaultProxy()
  };
  return data;
}

/** readRow 归一后的 DownloadRow 形状（22 列，completed 由入参给） */
function baseRow(completed: number): DownloadRow {
  const row: DownloadRow = {
    id: 'row-id',
    completed: completed,
    name: 'file.bin',
    dateAdded: 1727500000000,
    size: 1000,
    status: 1,
    progress: 0,
    downloadType: 'application/octet-stream',
    fileNameFetchMode: 0,
    maxSpeedLimitInKiB: 0,
    targetDir: '/data/dir',
    primaryUrl: 'http://probe.local/f.bin',
    refererUrl: null,
    auth: 0,
    user: null,
    pass: null,
    proxy: 0,
    proxyHost: null,
    proxyPort: 0,
    proxyUser: null,
    proxyPass: null,
    proxyType: 1
  };
  return row;
}

export default function recordMappingTest(): void {
  describe('RecordMapping', () => {
    it('rowFromRecord_addPath_defaults', 0, () => {
      const data: RecordData = addShapeRecord(DownloadStatus.Stopped);
      const row: DownloadRow = rowFromRecord(data);
      expect(row.id).assertEqual('test-id');
      expect(row.completed).assertEqual(0);
      expect(row.status).assertEqual(1);
      expect(row.progress).assertEqual(0);
      expect(row.dateAdded).assertEqual(1727500000000);
      expect(row.size).assertEqual(1000);
      expect(row.auth).assertEqual(0);
      expect(row.user).assertNull();
      expect(row.pass).assertNull();
      expect(row.proxy).assertEqual(0);
      expect(row.proxyHost).assertNull();
      expect(row.proxyPort).assertEqual(0);
      expect(row.proxyUser).assertNull();
      expect(row.proxyPass).assertNull();
      // proxy_type 恒硬编码 1（DownloadList.cs:219），与 Proxy 实际取值无关
      expect(row.proxyType).assertEqual(1);
    });

    it('rowFromRecord_withAuthAndProxy', 0, () => {
      const data: RecordData = addShapeRecord(DownloadStatus.Waiting);
      const auth: AuthenticationInfo = { userName: 'user1', password: 'pass1' };
      data.authentication = auth;
      const proxy: ProxyInfo = {
        proxyType: ProxyType.Custom,
        host: '192.168.1.2',
        port: 8080,
        userName: 'puser',
        password: 'ppass'
      };
      data.proxy = proxy;
      const row: DownloadRow = rowFromRecord(data);
      expect(row.auth).assertEqual(1);
      expect(row.user).assertEqual('user1');
      expect(row.pass).assertEqual('pass1');
      expect(row.proxy).assertEqual(2);
      expect(row.proxyHost).assertEqual('192.168.1.2');
      expect(row.proxyPort).assertEqual(8080);
      expect(row.proxyUser).assertEqual('puser');
      expect(row.proxyPass).assertEqual('ppass');
      expect(row.status).assertEqual(3);
      expect(row.proxyType).assertEqual(1);
    });

    it('recordFromRow_inProgress_forcesStopped', 0, () => {
      const row: DownloadRow = baseRow(0);
      row.status = 0; // raw Downloading（上一会话写入值）
      row.progress = 55;
      const data: RecordData = recordFromRow(row);
      expect(data.kind).assertEqual(DownloadKind.InProgress);
      // 强制规则 R2：completed=0 行读回一律 Stopped(1)，raw status 丢弃
      expect(data.status).assertEqual(1);
      expect(data.progress).assertEqual(55);
    });

    it('recordFromRow_finished_noProgress', 0, () => {
      const row: DownloadRow = baseRow(1);
      row.status = 2; // 完成行 raw status 保留（C# 对完成行不读 status，此处读取仅为单模型完整性）
      row.progress = 55;
      const data: RecordData = recordFromRow(row);
      expect(data.kind).assertEqual(DownloadKind.Finished);
      expect(data.progress).assertEqual(0);
      expect(data.status).assertEqual(2);
    });

    it('recordFromRow_authGate', 0, () => {
      // auth=1 且 user=null → 不构造
      const rowNoUser: DownloadRow = baseRow(0);
      rowNoUser.auth = 1;
      rowNoUser.user = null;
      rowNoUser.pass = 'pass1';
      expect(recordFromRow(rowNoUser).authentication).assertNull();
      // auth=1 且 user!=null → 构造（pass 可 null，D14）
      const rowWithUser: DownloadRow = baseRow(0);
      rowWithUser.auth = 1;
      rowWithUser.user = 'user1';
      rowWithUser.pass = null;
      const authInfo: AuthenticationInfo | null = recordFromRow(rowWithUser).authentication;
      // hypium Assert 面无 assertNotNull（本机 hypium src_static/interface.ets 核实）——用谓词等价断言
      expect(authInfo === null).assertEqual(false);
      if (authInfo !== null) {
        expect(authInfo.userName).assertEqual('user1');
        expect(authInfo.password).assertNull();
      }
      // auth=0 → 不构造（即使 user 有值）
      const rowNoAuth: DownloadRow = baseRow(0);
      rowNoAuth.auth = 0;
      rowNoAuth.user = 'user1';
      rowNoAuth.pass = 'pass1';
      expect(recordFromRow(rowNoAuth).authentication).assertNull();
    });

    it('recordFromRow_proxyUnconditional', 0, () => {
      // 全缺省行 → System(0)/port 0/其余 null（无条件构造，R4）
      const rowDefault: DownloadRow = baseRow(0);
      const dataDefault: RecordData = recordFromRow(rowDefault);
      expect(dataDefault.proxy.proxyType).assertEqual(0);
      expect(dataDefault.proxy.port).assertEqual(0);
      expect(dataDefault.proxy.host).assertNull();
      expect(dataDefault.proxy.userName).assertNull();
      expect(dataDefault.proxy.password).assertNull();
      // 有值行 → 透传
      const rowCustom: DownloadRow = baseRow(0);
      rowCustom.proxy = 2;
      rowCustom.proxyHost = '192.168.1.2';
      rowCustom.proxyPort = 8080;
      rowCustom.proxyUser = 'puser';
      rowCustom.proxyPass = 'ppass';
      const dataCustom: RecordData = recordFromRow(rowCustom);
      expect(dataCustom.proxy.proxyType).assertEqual(2);
      expect(dataCustom.proxy.host).assertEqual('192.168.1.2');
      expect(dataCustom.proxy.port).assertEqual(8080);
      expect(dataCustom.proxy.userName).assertEqual('puser');
      expect(dataCustom.proxy.password).assertEqual('ppass');
    });

    it('recordFromRow_nullTextPassThrough', 0, () => {
      const row: DownloadRow = baseRow(0);
      row.name = null;
      row.targetDir = null;
      row.refererUrl = null;
      row.downloadType = null;
      const data: RecordData = recordFromRow(row);
      expect(data.name).assertNull();
      expect(data.targetDir).assertNull();
      expect(data.refererUrl).assertNull();
      expect(data.downloadType).assertNull();
      expect(data.id).assertEqual('row-id');
    });

    it('roundTrip_addShape_forcesStoppedOnReload', 0, () => {
      // 重启读回强制的纯函数级证明：status=Waiting(3) 的记录写入（写侧保留 3），
      // 读回（completed=0）强制 Stopped(1)
      const data: RecordData = addShapeRecord(DownloadStatus.Waiting);
      const row: DownloadRow = rowFromRecord(data);
      expect(row.status).assertEqual(3);
      const reloaded: RecordData = recordFromRow(row);
      expect(reloaded.status).assertEqual(1);
      expect(reloaded.kind).assertEqual(DownloadKind.InProgress);
      expect(reloaded.progress).assertEqual(0);
    });

    it('computeProgress_truncates', 0, () => {
      expect(computeProgress(50, 100)).assertEqual(50);
      expect(computeProgress(1, 3)).assertEqual(33);
      expect(computeProgress(299, 300)).assertEqual(99);
      expect(computeProgress(300, 300)).assertEqual(100);
    });

    it('computeProgress_nonPositiveSize_returnsZero', 0, () => {
      expect(computeProgress(100, 0)).assertEqual(0);
      expect(computeProgress(100, -5)).assertEqual(0);
    });

    it('computeInitialStatus_matchesApplicationAddItemToTop', 0, () => {
      expect(computeInitialStatus(true)).assertEqual(3);
      expect(computeInitialStatus(false)).assertEqual(1);
    });

    it('joinTempDir_combinesBaseAndId', 0, () => {
      expect(joinTempDir('/data/app/el2/100/base/files/temp', 'abc-123'))
        .assertEqual('/data/app/el2/100/base/files/temp/abc-123');
      expect(joinTempDir('', 'abc-123')).assertEqual('/abc-123');
    });

    it('updateEntryRowFromRecord_15colShape', 0, () => {
      // UpdateEntryRow 类型上无 status/progress/completed 字段（编译期防"顺手多更新一列"，
      // DownloadList.cs:239-243 SET 清单），此处锁 15 个字段值
      const data: RecordData = addShapeRecord(DownloadStatus.Stopped);
      const auth: AuthenticationInfo = { userName: 'user1', password: null };
      data.authentication = auth;
      const row: UpdateEntryRow = updateEntryRowFromRecord(data);
      expect(row.name).assertEqual('file.bin');
      expect(row.dateAdded).assertEqual(1727500000000);
      expect(row.size).assertEqual(1000);
      expect(row.downloadType).assertEqual('application/octet-stream');
      expect(row.targetDir).assertEqual('/data/dir');
      expect(row.primaryUrl).assertEqual('http://probe.local/f.bin');
      expect(row.auth).assertEqual(1);
      expect(row.user).assertEqual('user1');
      expect(row.pass).assertNull();
      expect(row.proxy).assertEqual(0);
      expect(row.proxyHost).assertNull();
      expect(row.proxyPort).assertEqual(0);
      expect(row.proxyUser).assertNull();
      expect(row.proxyPass).assertNull();
      expect(row.proxyType).assertEqual(1);
    });
  });
}
