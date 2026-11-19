/*
 * U1.1 数据层：RelationalStore 单例（对照 AppDB.cs + DownloadList.cs，设计书 §2.1/§3.2/§3.3/§5.4）。
 * 初始化序列对照 AppDB.Init（AppDB.cs:38-62）：getRdbStore 自动建库文件（等价 CreateFile+Open，
 * 库文件落平台 databaseDir/downloads.db，D2）→ executeSql(DDL)（等价 SchemaInitializer.Init）→
 * 单例持有（等价挂 DownloadList）。
 * 线程模型（D8）：C# lock(db) 串行化不复刻——RelationalStore 线程安全 + 单例 ready Promise 门；
 * initialize 失败同样 memoize（readyPromise 保持 rejected）→ 后续 CRUD 全部走 catch 返 false/null/空表，
 * 等价 C# Init 失败后应用继续运行、操作吞异常的语义（AppDB.cs:56-60）。
 * 异常语义 1:1（§3.3）：DownloadList 全部公开方法 try{return true}catch{return false|null|空表}；
 * 写操作用 executeSql（C# ExecuteNonQuery 返回值同样被丢弃，0 行受影响也返 true）。
 * U1.2 次序约束：LoadDownloadList 必须 await initialize() 之后调用（C# Application.cs:31 的
 * Init→LoadDownloadList 顺序强保证在异步侧由 ready 门承接）。
 * 业务日志：hilog domain 0x0000、tag 'DownloadStore'，绝不输出 [XDM_PROBE] 前缀（ProbeKit 是唯一探针出口）。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DownloadKind, DownloadStatus, RecordData } from '../../model/DownloadTypes';
import { DownloadRecord } from '../../model/DownloadRecord';
import { AdaptiveSourceDescriptor, parseAdaptiveSource, serializeAdaptiveSource } from '../../model/AdaptiveSource';
import { BridgeInboxItem, parseBridgeInboxItem, serializeBridgeInboxItem } from '../../model/DownloadCreationRequest';
import { DownloadRequestContext, parseDownloadRequestContext,
  serializeDownloadRequestContext } from '../../model/DownloadRequestContext';
import { DownloadRow, UpdateEntryRow, rowFromRecord, recordFromRow, updateEntryRowFromRecord } from './RecordMapping';
import { DownloadRunRequest, cloneDownloadRunRequest } from '../../model/DownloadRunRequest';
import { publishCommittedRequest, forgetRequest } from '../engine/DownloadRequestState';

/** 库名（对照 Application.cs:29 Path.Combine(Config.AppDir, "downloads.db")） */
export const DOWNLOADS_DB_NAME: string = 'downloads.db';

/** 表名（全 SQL 共用） */
const DDL_REQUEST_CONTEXT: string = 'CREATE TABLE IF NOT EXISTS download_request_context(' +
  'id TEXT PRIMARY KEY, payload TEXT NOT NULL)';
const SQL_SAVE_REQUEST_CONTEXT: string = 'INSERT OR REPLACE INTO download_request_context(id,payload) ' +
  'SELECT id,? FROM downloads WHERE id=?';
const SQL_DELETE_REQUEST_CONTEXT: string = 'DELETE FROM download_request_context WHERE id=?';
const DDL_REQUEST_REVISION: string = 'CREATE TABLE IF NOT EXISTS download_request_revision(' +
  'id TEXT PRIMARY KEY, revision INTEGER NOT NULL)';
const SQL_SAVE_REQUEST_REVISION: string = 'INSERT OR REPLACE INTO download_request_revision(id,revision) VALUES(?,?)';
/** HLS/DASH/dual-source descriptor side table (additive; Http rows have none). */
const DDL_ADAPTIVE_SOURCE: string = 'CREATE TABLE IF NOT EXISTS download_adaptive_source(' +
  'id TEXT PRIMARY KEY, payload TEXT NOT NULL)';
const SQL_SAVE_ADAPTIVE_SOURCE: string = 'INSERT OR REPLACE INTO download_adaptive_source(id,payload) VALUES(?,?)';
const SQL_DELETE_ADAPTIVE_SOURCE: string = 'DELETE FROM download_adaptive_source WHERE id=?';
const DDL_BRIDGE_INBOX: string = 'CREATE TABLE IF NOT EXISTS bridge_inbox(' +
  'id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at INT NOT NULL)';

interface StoredCreation {
  id: string;
  args: Array<relationalStore.ValueType>;
  payload: string;
  request: DownloadRunRequest;
  sourcePayload: string | null;
}

/** DDL 逐字对照 SchemaInitializer.cs:13-36：22 列名与顺序为根基（SELECT * 读回/投影/探针 S1 观测锚），
 * WITHOUT ROWID 尾缀保留（D15：目标平台建表失败才去尾缀降级并在单元报告注明，禁静默改列序） */
const DDL_DOWNLOADS: string = 'CREATE TABLE IF NOT EXISTS downloads(' +
'id TEXT PRIMARY KEY, completed INT, name TEXT, date_added INT, size INT, status INT, progress INT, ' +
'download_type TEXT, filenamefetchmode INT, maxspeedlimitinkib INT, targetdir TEXT, primary_url TEXT, ' +
'referer_url TEXT, auth INT, user TEXT, pass TEXT, proxy INT, proxy_host TEXT, proxy_port INT, ' +
'proxy_user TEXT, proxy_pass TEXT, proxy_type INT) WITHOUT ROWID';

/** D15 降级 DDL：仅当带尾缀 DDL 建表报错时重试用（列名/列序逐字不变，仅去 WITHOUT ROWID；
 * 降级实例经探针 S1 ddlTail=absent 可观测并回写单元报告） */
const DDL_DOWNLOADS_NO_ROWID_TAIL: string = 'CREATE TABLE IF NOT EXISTS downloads(' +
'id TEXT PRIMARY KEY, completed INT, name TEXT, date_added INT, size INT, status INT, progress INT, ' +
'download_type TEXT, filenamefetchmode INT, maxspeedlimitinkib INT, targetdir TEXT, primary_url TEXT, ' +
'referer_url TEXT, auth INT, user TEXT, pass TEXT, proxy INT, proxy_host TEXT, proxy_port INT, ' +
'proxy_user TEXT, proxy_pass TEXT, proxy_type INT)';

/** INSERT 22 列（对照 DownloadList.cs:187-196 cmdInsertOne 列序 = rowFromRecord 字段序） */
const SQL_INSERT_DOWNLOAD: string = 'INSERT INTO downloads(id, completed, name, date_added, size, status, ' +
'progress, download_type, filenamefetchmode, maxspeedlimitinkib, targetdir, primary_url, referer_url, ' +
'auth, user, pass, proxy, proxy_host, proxy_port, proxy_user, proxy_pass, proxy_type) ' +
'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/** 对照 DownloadList.cs:280（cmdUpdateProgress） */
const SQL_UPDATE_PROGRESS: string = 'UPDATE downloads SET progress=? WHERE id=?';
/** 对照 DownloadList.cs:367（cmdUpdateStatus） */
const SQL_UPDATE_STATUS: string = 'UPDATE downloads SET status=? WHERE id=?';
/** 对照 DownloadList.cs:340-341（cmdMarkFinished）；bindArgs 按 SQL 占位序：folder,file,finalFileSize,1,id */
const SQL_MARK_FINISHED: string = 'UPDATE downloads SET targetdir=?, name=?, size=?, completed=? WHERE id=?';
/** 对照 DownloadList.cs:239-243（cmdUpdateOne 15 列 SET 清单） */
const SQL_UPDATE_ENTRY: string = 'UPDATE downloads SET name=?, date_added=?, size=?, download_type=?, ' +
'targetdir=?, primary_url=?, auth=?, user=?, pass=?, proxy=?, proxy_host=?, proxy_port=?, proxy_user=?, ' +
'proxy_pass=?, proxy_type=? WHERE id=?';
/** 对照 DownloadList.cs:456（cmdDelete） */
const SQL_DELETE_BY_ID: string = 'DELETE FROM downloads WHERE id=?';
/** 对照 DownloadList.cs:122（cmdFetchOne） */
const SQL_SELECT_WITH_CONTEXT: string = 'SELECT downloads.*, ctx.payload AS request_context_payload, ' +
  'COALESCE(rev.revision,0) AS request_revision, src.payload AS adaptive_source_payload FROM downloads ' +
  'LEFT JOIN download_request_context ctx ON downloads.id=ctx.id ' +
  'LEFT JOIN download_request_revision rev ON downloads.id=rev.id ' +
  'LEFT JOIN download_adaptive_source src ON downloads.id=src.id';
const SQL_SELECT_BY_ID: string = SQL_SELECT_WITH_CONTEXT + ' WHERE downloads.id=?';
/** 对照 DownloadList.cs:42（cmdFetchAll） */
const SQL_SELECT_ALL: string = SQL_SELECT_WITH_CONTEXT;

/** 双列表装载结果（对照 LoadDownloads 的 out 双参，DownloadList.cs:27-29） */
export interface DownloadLists {
  inProgress: DownloadRecord[];
  finished: DownloadRecord[];
}

export class DownloadStore {
  private static instance: DownloadStore | undefined = undefined;

  /** 已就绪的 RdbStore 句柄（readyPromise resolve 后必非 undefined） */
  private rdbStore: relationalStore.RdbStore | undefined = undefined;
  /** memoized ready 门：首次 initialize 触发建库建表；失败保持 rejected（后续 CRUD 全走异常路径） */
  private readyPromise: Promise<void> | undefined = undefined;

  private constructor() {
  }

  /** 惰性单例（对照 AppDB.cs:23-36 双检锁单例；JS 单线程下无竞态） */
  static getInstance(): DownloadStore {
    if (DownloadStore.instance === undefined) {
      DownloadStore.instance = new DownloadStore();
    }
    return DownloadStore.instance;
  }

  /** ready 门（memoized，幂等）：EntryAbility.onCreate fire-and-forget 调用；探针/U1.2 显式 await */
  initialize(context: common.Context): Promise<void> {
    if (this.readyPromise === undefined) {
      this.readyPromise = this.doInitialize(context);
    }
    return this.readyPromise;
  }

  private async doInitialize(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DOWNLOADS_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    try {
      const rdb: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      await this.createTables(rdb);
      // Side-table migration is additive: legacy downloads retain their exact 22-column schema.
      await rdb.executeSql(DDL_REQUEST_CONTEXT);
      await rdb.executeSql(DDL_BRIDGE_INBOX);
      await rdb.executeSql(DDL_REQUEST_REVISION);
      await rdb.executeSql(DDL_ADAPTIVE_SOURCE);
      this.rdbStore = rdb;
    } catch (e) {
      // rethrow 保持 ready 门 memoize rejected 语义；`as Error`：arkts-limited-throw 只接受
      // 静态类型 Error 及其类子类，BusinessError 接口不可直接 throw（cast 不改变运行时对象）
      const err = e as BusinessError;
      this.logFailure('initialize', err);
      throw err as Error;
    }
  }

  /** 建表（D15 降级预案，设计书 §2.1/§8）：先带 WITHOUT ROWID 尾缀，目标平台拒绝则去尾缀重试
   * （列名/列序不变，CRUD 等价）；二次失败上抛 → ready 门 memoize rejected，后续 CRUD 走吞异常路径。
   * 降级实例由探针 S1 ddlTail=absent 观测到后须在单元报告注明。 */
  private async createTables(rdb: relationalStore.RdbStore): Promise<void> {
    try {
      await rdb.executeSql(DDL_DOWNLOADS);
      return;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'DownloadStore', '%{public}s',
        'ddl with WITHOUT ROWID rejected, retry without suffix errCode=' + String(err.code) +
        ' errMessage=' + (err.message ?? ''));
    }
    try {
      await rdb.executeSql(DDL_DOWNLOADS_NO_ROWID_TAIL);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('createTables', err);
      throw err as Error;
    }
  }

  /** 取句柄：未 initialize 或 ready 门 rejected（建库/建表失败）→ 抛错，由各 CRUD 的 catch 吞掉 */
  private async db(): Promise<relationalStore.RdbStore> {
    const ready = this.readyPromise;
    if (ready === undefined) {
      throw new Error('DownloadStore not initialized');
    }
    await ready;
    const rdb: relationalStore.RdbStore | undefined = this.rdbStore;
    if (rdb === undefined) {
      throw new Error('DownloadStore not ready');
    }
    return rdb;
  }

  /** 新增下载行（对照 AddNewDownload，DownloadList.cs:179-229） */
  async add(record: DownloadRecord): Promise<boolean> {
    try {
      const row: DownloadRow = rowFromRecord(record);
      const payload: string = serializeDownloadRequestContext(record.requestContext);
      const sourcePayload: string | null = record.adaptiveSource === null ? null
        : serializeAdaptiveSource(record.adaptiveSource);
      const request: DownloadRunRequest = this.requestSnapshot(row.primaryUrl ?? '', payload, 0);
      // 防御：C# AddNewDownload 类型层限定 InProgressDownloadItem 并硬编码 completed=0（DownloadList.cs:199），
      // ArkTS 侧在存储层强制，防后续单元把完成形态记录误入 add（三轮审查遗留项）
      row.completed = DownloadKind.InProgress;
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [
        row.id, row.completed, row.name, row.dateAdded, row.size, row.status,
        row.progress, row.downloadType, row.fileNameFetchMode, row.maxSpeedLimitInKiB,
        row.targetDir, row.primaryUrl, row.refererUrl, row.auth, row.user, row.pass,
        row.proxy, row.proxyHost, row.proxyPort, row.proxyUser, row.proxyPass, row.proxyType
      ];
      await this.inTransaction(rdb, async (tx: relationalStore.Transaction): Promise<void> => {
        await tx.execute(SQL_INSERT_DOWNLOAD, args);
        await tx.execute(SQL_SAVE_REQUEST_CONTEXT, [payload, row.id]);
        await tx.execute(SQL_SAVE_REQUEST_REVISION, [row.id, 0]);
        if (sourcePayload !== null) {
          await tx.execute(SQL_SAVE_ADAPTIVE_SOURCE, [row.id, sourcePayload]);
        }
      });
      publishCommittedRequest(row.id, request);
      record.requestRevision = 0;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('add', err);
      return false;
    }
  }

  /** 更新进度（对照 UpdateDownloadProgress，DownloadList.cs:272-295） */
  async updateProgress(id: string, progress: number): Promise<boolean> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [progress, id];
      await rdb.executeSql(SQL_UPDATE_PROGRESS, args);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('updateProgress', err);
      return false;
    }
  }

  /** 更新状态（对照 UpdateDownloadStatus，DownloadList.cs:359-380）；写入值重启后不生效是预期
   * （读回强制规则 R2：completed=0 行读回一律 Stopped——设计书 D5） */
  async updateStatus(id: string, status: DownloadStatus): Promise<boolean> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [status, id];
      await rdb.executeSql(SQL_UPDATE_STATUS, args);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('updateStatus', err);
      return false;
    }
  }

  /** 完成落库（对照 MarkAsFinished，DownloadList.cs:332-357）：targetdir/name/size/completed 四列 */
  async markAsFinished(id: string, finalFileSize: number, file: string, folder: string): Promise<boolean> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [folder, file, finalFileSize, 1, id];
      await rdb.executeSql(SQL_MARK_FINISHED, args);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('markAsFinished', err);
      return false;
    }
  }

  /** 15 列更新（对照 UpdateDownloadEntry，DownloadList.cs:231-270；Application.cs:114-145 完成链消费） */
  async updateDownloadEntry(record: DownloadRecord): Promise<boolean> {
    try {
      const row: UpdateEntryRow = updateEntryRowFromRecord(record);
      const id: string = record.id;
      const payload: string = serializeDownloadRequestContext(record.requestContext);
      const expected: number = record.requestRevision;
      this.checkRevision(expected);
      const request: DownloadRunRequest = this.requestSnapshot(row.primaryUrl ?? '', payload, expected + 1);
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [
        row.name, row.dateAdded, row.size, row.downloadType, row.targetDir, row.primaryUrl,
        row.auth, row.user, row.pass, row.proxy, row.proxyHost, row.proxyPort,
        row.proxyUser, row.proxyPass, row.proxyType, id
      ];
      await this.inTransaction(rdb, async (tx: relationalStore.Transaction): Promise<void> => {
        const current: number = await this.readRevision(tx, id);
        if (current !== expected) { throw new Error('Download request revision conflict'); }
        await tx.execute(SQL_UPDATE_ENTRY, args);
        await tx.execute(SQL_SAVE_REQUEST_CONTEXT, [payload, id]);
        await tx.execute(SQL_SAVE_REQUEST_REVISION, [id, request.revision]);
      });
      publishCommittedRequest(id, request);
      record.requestRevision = request.revision;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('updateDownloadEntry', err);
      return false;
    }
  }

  /** 按 id 删除（对照 RemoveDownloadById，DownloadList.cs:448-468） */
  async remove(id: string): Promise<boolean> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [id];
      await this.inTransaction(rdb, async (tx: relationalStore.Transaction): Promise<void> => {
        await tx.execute(SQL_DELETE_REQUEST_CONTEXT, args);
        await tx.execute('DELETE FROM download_request_revision WHERE id=?', args);
        await tx.execute(SQL_DELETE_ADAPTIVE_SOURCE, args);
        await tx.execute(SQL_DELETE_BY_ID, args);
      });
      forgetRequest(id);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('remove', err);
      return false;
    }
  }

  /** 按 id 查单条（对照 GetDownloadById，DownloadList.cs:114-177）：未命中/异常返 null */
  async getDownloadById(id: string): Promise<DownloadRecord | null> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const args: Array<relationalStore.ValueType> = [id];
      const rs: relationalStore.ResultSet = await rdb.querySql(SQL_SELECT_BY_ID, args);
      let found: DownloadRecord | null = null;
      try {
        if (rs.goToNextRow()) {
          found = this.toRecord(rs);
        }
      } finally {
        rs.close();
      }
      return found;
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('getDownloadById', err);
      return null;
    }
  }

  /** LinkRefresher: commit URL and credentials together; missing id is not a successful refresh.
   * Caller updates the in-memory record only after true. Does not create a new download. */
  async refreshRequestContext(id: string, url: string, context: DownloadRequestContext): Promise<boolean> {
    return await this.refreshCommittedRequest(id, url, context) !== null;
  }

  async refreshCommittedRequest(id: string, url: string,
    context: DownloadRequestContext): Promise<DownloadRunRequest | null> {
    try {
      const payload: string = serializeDownloadRequestContext(context);
      const request: DownloadRunRequest = this.requestSnapshot(url, payload, 0);
      const rdb: relationalStore.RdbStore = await this.db();
      await this.inTransaction(rdb, async (tx: relationalStore.Transaction): Promise<void> => {
        request.revision = await this.readRevision(tx, id) + 1;
        this.checkRevision(request.revision);
        await tx.execute('UPDATE downloads SET primary_url=? WHERE id=?', [url, id]);
        await tx.execute(SQL_SAVE_REQUEST_CONTEXT, [payload, id]);
        await tx.execute(SQL_SAVE_REQUEST_REVISION, [id, request.revision]);
      });
      publishCommittedRequest(id, request);
      return cloneDownloadRunRequest(request);
    } catch (e) {
      this.logFailure('refreshCommittedRequest', e as BusinessError);
      return null;
    }
  }

  private checkRevision(revision: number): void {
    if (!Number.isSafeInteger(revision) || revision < 0) { throw new Error('Invalid request revision'); }
  }

  private async readRevision(tx: relationalStore.Transaction, id: string): Promise<number> {
    const rows: relationalStore.ResultSet = await tx.querySql(
      'SELECT COALESCE(rev.revision,0) AS request_revision FROM downloads ' +
      'LEFT JOIN download_request_revision rev ON downloads.id=rev.id WHERE downloads.id=?', [id]);
    try {
      if (!rows.goToNextRow()) { throw new Error('Download target missing'); }
      const revision: number = this.readInt(rows, 'request_revision');
      this.checkRevision(revision);
      return revision;
    } finally {
      rows.close();
    }
  }

  private requestSnapshot(url: string, payload: string, revision: number): DownloadRunRequest {
    this.checkRevision(revision);
    const context: DownloadRequestContext | null = parseDownloadRequestContext(payload);
    if (context === null) { throw new Error('Invalid request context'); }
    const request: DownloadRunRequest = new DownloadRunRequest();
    request.url = url;
    request.context = context;
    request.revision = revision;
    return request;
  }

  /** Durable receipt for a confirmation dialog; duplicate ids never replace accepted input. */
  async saveBridgeInbox(item: BridgeInboxItem): Promise<boolean> {
    try {
      const payload: string = serializeBridgeInboxItem(item);
      const id: string = item.id;
      const createdAt: number = item.createdAt;
      const rdb: relationalStore.RdbStore = await this.db();
      await rdb.executeSql('INSERT INTO bridge_inbox(id,payload,created_at) VALUES(?,?,?)',
        [id, payload, createdAt]);
      return true;
    } catch (e) {
      this.logFailure('saveBridgeInbox', e as BusinessError);
      return false;
    }
  }

  async queryBridgeInbox(): Promise<BridgeInboxItem[]> {
    const items: BridgeInboxItem[] = [];
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const rows: relationalStore.ResultSet = await rdb.querySql(
        'SELECT id,payload FROM bridge_inbox ORDER BY created_at,id');
      try {
        while (rows.goToNextRow()) {
          try {
            const item: BridgeInboxItem | null = parseBridgeInboxItem(this.readText(rows, 'payload') ?? '');
            if (item === null || item.id !== this.readText(rows, 'id')) {
              throw new Error('Invalid stored bridge inbox item');
            }
            items.push(item);
          } catch (rowError) {
            this.logFailure('queryBridgeInbox skipped invalid row', rowError as BusinessError);
          }
        }
      } finally {
        rows.close();
      }
    } catch (e) {
      this.logFailure('queryBridgeInbox', e as BusinessError);
      // The caller must distinguish database failure from an empty durable queue.
      throw new Error('Bridge inbox unavailable');
    }
    return items;
  }

  async removeBridgeInbox(id: string): Promise<boolean> {
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      await rdb.executeSql('DELETE FROM bridge_inbox WHERE id=?', [id]);
      return true;
    } catch (e) {
      this.logFailure('removeBridgeInbox', e as BusinessError);
      return false;
    }
  }

  /** One transaction owns the inbox claim and all selected downloads. A concurrent second
   * confirmation observes the missing inbox and cannot create a second batch. */
  async promoteBridgeInbox(id: string, records: DownloadRecord[]): Promise<boolean> {
    try {
      if (records.length === 0) {
        return false;
      }
      const writes: StoredCreation[] = [];
      for (let i = 0; i < records.length; i++) {
        const row: DownloadRow = rowFromRecord(records[i]);
        const args: Array<relationalStore.ValueType> = [
          row.id, DownloadKind.InProgress, row.name, row.dateAdded, row.size, row.status,
          row.progress, row.downloadType, row.fileNameFetchMode, row.maxSpeedLimitInKiB,
          row.targetDir, row.primaryUrl, row.refererUrl, row.auth, row.user, row.pass,
          row.proxy, row.proxyHost, row.proxyPort, row.proxyUser, row.proxyPass, row.proxyType
        ];
        const payload: string = serializeDownloadRequestContext(records[i].requestContext);
        const source: AdaptiveSourceDescriptor | null = records[i].adaptiveSource;
        const write: StoredCreation = { id: row.id, args: args, payload: payload,
          request: this.requestSnapshot(row.primaryUrl ?? '', payload, 0),
          sourcePayload: source === null ? null : serializeAdaptiveSource(source) };
        writes.push(write);
      }
      const rdb: relationalStore.RdbStore = await this.db();
      await this.inTransaction(rdb, async (tx: relationalStore.Transaction): Promise<void> => {
        const row: relationalStore.ResultSet = await tx.querySql('SELECT id FROM bridge_inbox WHERE id=?', [id]);
        try {
          if (!row.goToNextRow()) {
            throw new Error('Bridge inbox already consumed');
          }
        } finally {
          row.close();
        }
        for (let i = 0; i < writes.length; i++) {
          await tx.execute(SQL_INSERT_DOWNLOAD, writes[i].args);
          await tx.execute(SQL_SAVE_REQUEST_CONTEXT, [writes[i].payload, writes[i].id]);
          await tx.execute(SQL_SAVE_REQUEST_REVISION, [writes[i].id, 0]);
          const sourcePayload: string | null = writes[i].sourcePayload;
          if (sourcePayload !== null) {
            await tx.execute(SQL_SAVE_ADAPTIVE_SOURCE, [writes[i].id, sourcePayload]);
          }
        }
        await tx.execute('DELETE FROM bridge_inbox WHERE id=?', [id]);
      });
      for (let i = 0; i < writes.length; i++) {
        publishCommittedRequest(writes[i].id, writes[i].request);
        records[i].requestRevision = 0;
      }
      return true;
    } catch (e) {
      this.logFailure('promoteBridgeInbox', e as BusinessError);
      return false;
    }
  }

  /** SDK API14+ dedicated transaction keeps unrelated asynchronous CRUD outside this transaction.
   * All reads use a single LEFT JOIN statement, so URL/context come from the same snapshot. */
  private async inTransaction(rdb: relationalStore.RdbStore,
    operation: (tx: relationalStore.Transaction) => Promise<void>): Promise<void> {
    const options: relationalStore.TransactionOptions = {
      transactionType: relationalStore.TransactionType.IMMEDIATE
    };
    let tx: relationalStore.Transaction | undefined = undefined;
    try {
      tx = await rdb.createTransaction(options);
      await operation(tx);
      await tx.commit();
    } catch (e) {
      try {
        if (tx !== undefined) {
          await tx.rollback();
        }
      } catch (rollbackError) {
        this.logFailure('rollback', rollbackError as BusinessError);
      }
      throw e as Error;
    }
  }

  /** 全表装载（对照 LoadDownloads(QueryMode.All)，DownloadList.cs:27-112）：completed 分型进双列表；异常返空表 */
  async queryAll(): Promise<DownloadLists> {
    const inProgress: DownloadRecord[] = [];
    const finished: DownloadRecord[] = [];
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const rs: relationalStore.ResultSet = await rdb.querySql(SQL_SELECT_ALL);
      try {
        while (rs.goToNextRow()) {
          try {
            const record: DownloadRecord = this.toRecord(rs);
            if (record.kind === DownloadKind.Finished) {
              finished.push(record);
            } else {
              inProgress.push(record);
            }
          } catch (rowError) {
            this.logFailure('queryAll skipped invalid row', rowError as BusinessError);
          }
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('queryAll', err);
    }
    const result: DownloadLists = { inProgress: inProgress, finished: finished };
    return result;
  }

  /** 进行中列表（对照 LoadDownloads(QueryMode.InProgress)，DownloadList.cs:471-476） */
  async queryInProgress(): Promise<DownloadRecord[]> {
    return this.queryByCompleted(DownloadKind.InProgress);
  }

  /** 已完成列表（对照 LoadDownloads(QueryMode.Finished)） */
  async queryFinished(): Promise<DownloadRecord[]> {
    return this.queryByCompleted(DownloadKind.Finished);
  }

  /** 条件查询共用体（对照 cmdFetchConditional 'SELECT * FROM downloads WHERE completed=@completed'，:50） */
  private async queryByCompleted(kind: DownloadKind): Promise<DownloadRecord[]> {
    const rows: DownloadRecord[] = [];
    try {
      const rdb: relationalStore.RdbStore = await this.db();
      const rs: relationalStore.ResultSet = await rdb.querySql(SQL_SELECT_WITH_CONTEXT +
        ' WHERE downloads.completed=?', [kind]);
      try {
        while (rs.goToNextRow()) {
          try {
            rows.push(this.toRecord(rs));
          } catch (rowError) {
            this.logFailure('queryByCompleted skipped invalid row', rowError as BusinessError);
          }
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('queryByCompleted', err);
    }
    return rows;
  }

  /** 行装配：ResultSet → DownloadRow（NULL 归一）→ recordFromRow（强制规则 R1-R5）→ @Observed 实例字段拷贝 */
  private toRecord(rs: relationalStore.ResultSet): DownloadRecord {
    const row: DownloadRow = this.readRow(rs);
    const data: RecordData = recordFromRow(row);
    const record: DownloadRecord = new DownloadRecord();
    record.id = data.id;
    record.kind = data.kind;
    record.name = data.name;
    record.dateAdded = data.dateAdded;
    record.size = data.size;
    record.status = data.status;
    record.progress = data.progress;
    record.downloadType = data.downloadType;
    record.fileNameFetchMode = data.fileNameFetchMode;
    record.maxSpeedLimitInKiB = data.maxSpeedLimitInKiB;
    record.targetDir = data.targetDir;
    record.primaryUrl = data.primaryUrl;
    const payload: string | null = this.readText(rs, 'request_context_payload');
    if (payload !== null) {
      const context: DownloadRequestContext | null = parseDownloadRequestContext(payload);
      if (context === null) {
        // Corrupt stored credentials must not silently become an unauthenticated request.
        throw new Error('Invalid stored download request context');
      }
      record.requestContext = context;
    }
    const sourcePayload: string | null = this.readText(rs, 'adaptive_source_payload');
    if (sourcePayload !== null) {
      // A corrupt descriptor only matters before the engine persisted a plan; the downloader
      // reports AdaptiveSourceMissing instead of silently downgrading the row to Http.
      record.adaptiveSource = parseAdaptiveSource(sourcePayload);
      if (record.adaptiveSource === null) {
        hilog.error(0x0000, 'DownloadStore', '%{public}s', 'invalid adaptive source id=' + record.id);
      }
    }
    record.refererUrl = data.refererUrl;
    record.authentication = data.authentication;
    record.proxy = data.proxy;
    record.requestRevision = this.readInt(rs, 'request_revision');
    this.checkRevision(record.requestRevision);
    publishCommittedRequest(record.id, this.requestSnapshot(record.primaryUrl ?? '',
      serializeDownloadRequestContext(record.requestContext), record.requestRevision));
    // downloadSpeed/eta/downloadedBytes/tempDir 保持默认值：UI 派生与引擎期字段，重启后由消费方重算
    return record;
  }

  /** ResultSet → DownloadRow：按列名取下标（列序锚由 DDL+探针 S1 columnNames 互证），
   * isColumnNull 归一：int 列→0、text 列→null（D11）、id 列 null→''（D12，PRIMARY KEY 实际不可达） */
  private readRow(rs: relationalStore.ResultSet): DownloadRow {
    const row: DownloadRow = {
      id: this.readText(rs, 'id') ?? '',
      completed: this.readInt(rs, 'completed'),
      name: this.readText(rs, 'name'),
      dateAdded: this.readInt(rs, 'date_added'),
      size: this.readInt(rs, 'size'),
      status: this.readInt(rs, 'status'),
      progress: this.readInt(rs, 'progress'),
      downloadType: this.readText(rs, 'download_type'),
      fileNameFetchMode: this.readInt(rs, 'filenamefetchmode'),
      maxSpeedLimitInKiB: this.readInt(rs, 'maxspeedlimitinkib'),
      targetDir: this.readText(rs, 'targetdir'),
      primaryUrl: this.readText(rs, 'primary_url'),
      refererUrl: this.readText(rs, 'referer_url'),
      auth: this.readInt(rs, 'auth'),
      user: this.readText(rs, 'user'),
      pass: this.readText(rs, 'pass'),
      proxy: this.readInt(rs, 'proxy'),
      proxyHost: this.readText(rs, 'proxy_host'),
      proxyPort: this.readInt(rs, 'proxy_port'),
      proxyUser: this.readText(rs, 'proxy_user'),
      proxyPass: this.readText(rs, 'proxy_pass'),
      proxyType: this.readInt(rs, 'proxy_type')
    };
    return row;
  }

  /** 列读取（文本）：isColumnNull 归一 null（D11）；真实异常记日志后上抛——由调用链最外层
   * queryAll/queryByCompleted/getDownloadById 的 catch 接住，等价 C# 整表加载失败返 false/空表 */
  private readText(rs: relationalStore.ResultSet, column: string): string | null {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (rs.isColumnNull(idx)) {
        return null;
      }
      return rs.getString(idx);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('readText ' + column, err);
      throw err as Error;
    }
  }

  /** 列读取（整数）：isColumnNull 归一 0（D11）；真实异常记日志后上抛（同 readText 语义） */
  private readInt(rs: relationalStore.ResultSet, column: string): number {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (rs.isColumnNull(idx)) {
        return 0;
      }
      return rs.getLong(idx);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('readInt ' + column, err);
      throw err as Error;
    }
  }

  /** 业务日志（吞异常 1:1 对照 C# Log.Debug；不含 [XDM_PROBE] 前缀） */
  private logFailure(op: string, err: BusinessError): void {
    hilog.error(0x0000, 'DownloadStore', '%{public}s',
      op + ' failed errCode=' + String(err.code));
  }
}
