/*
 * U0.1 探针单元：P0-U0 环境自检（设计书 §6 步骤表）。
 * S1 设备形态（deviceType/osFullName）｜ S2 API 版本 ｜ S3 产品系列（marketName）
 * S4 应用包信息（bundleManager 查自身免权限）｜ S5 沙箱写盘自检（probe-selftest.txt）。
 * 红线：每步 catch BusinessError 记 err= 观测值不外抛；不做 PASS/FAIL 判定（S5 只输出
 * writeBytes/readBackBytes 观测值，不输出 match/differs）；每步骤恰一行由 ProbeKit 保证。
 */

import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';

const ENV_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '设备形态', autoRun: true },
  { stepNo: 'S2', title: 'API 版本', autoRun: true },
  { stepNo: 'S3', title: '产品系列', autoRun: true },
  { stepNo: 'S4', title: '应用包信息', autoRun: true },
  { stepNo: 'S5', title: '沙箱写盘自检', autoRun: true }
];

@Component
export struct ProbeEnv {
  private async runStep(stepNo: string): Promise<void> {
    const kit: ProbeKit = ProbeKit.getInstance();
    if (stepNo === 'S1') {
      this.runS1(kit);
      return;
    }
    if (stepNo === 'S2') {
      this.runS2(kit);
      return;
    }
    if (stepNo === 'S3') {
      this.runS3(kit);
      return;
    }
    if (stepNo === 'S4') {
      this.runS4(kit);
      return;
    }
    if (stepNo === 'S5') {
      this.runS5(kit);
      return;
    }
  }

  private runS1(kit: ProbeKit): void {
    const kvs: KeyValue[] = [];
    try {
      kvs.push(new KeyValue('deviceType', deviceInfo.deviceType));
      kvs.push(new KeyValue('osFullName', deviceInfo.osFullName));
    } catch (e) {
      const err = e as BusinessError;
      this.pushErrKvs(kvs, err.code, err.message ?? '');
    }
    kit.emit('S1', kvs);
  }

  private runS2(kit: ProbeKit): void {
    const kvs: KeyValue[] = [];
    try {
      kvs.push(new KeyValue('sdkApiVersion', String(deviceInfo.sdkApiVersion)));
      kvs.push(new KeyValue('firstApiVersion', String(deviceInfo.firstApiVersion)));
    } catch (e) {
      const err = e as BusinessError;
      this.pushErrKvs(kvs, err.code, err.message ?? '');
    }
    kit.emit('S2', kvs);
  }

  private runS3(kit: ProbeKit): void {
    const kvs: KeyValue[] = [];
    try {
      kvs.push(new KeyValue('marketName', deviceInfo.marketName));
    } catch (e) {
      const err = e as BusinessError;
      this.pushErrKvs(kvs, err.code, err.message ?? '');
    }
    kit.emit('S3', kvs);
  }

  private runS4(kit: ProbeKit): void {
    const kvs: KeyValue[] = [];
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      kvs.push(new KeyValue('bundleName', info.name));
      kvs.push(new KeyValue('versionName', info.versionName));
      kvs.push(new KeyValue('versionCode', String(info.versionCode)));
    } catch (e) {
      const err = e as BusinessError;
      this.pushErrKvs(kvs, err.code, err.message ?? '');
    }
    kit.emit('S4', kvs);
  }

  private runS5(kit: ProbeKit): void {
    const kvs: KeyValue[] = [];
    const fileName: string = 'probe-selftest.txt';
    kvs.push(new KeyValue('probeFile', fileName));
    try {
      const ctx = this.getUIContext().getHostContext();
      const filesDir: string = ctx?.filesDir ?? '';
      const path: string = filesDir + '/' + fileName;
      const content: string = kit.getRunId() + ' P0-U0 selftest';
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let writeBytes: number = 0;
      try {
        writeBytes = fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
      const readBack: string = fileIo.readTextSync(path);
      kvs.push(new KeyValue('writeBytes', String(writeBytes)));
      kvs.push(new KeyValue('readBackBytes', String(readBack.length)));
    } catch (e) {
      const err = e as BusinessError;
      this.pushErrKvs(kvs, err.code, err.message ?? '');
    }
    kit.emit('S5', kvs);
  }

  /** 观测值键组：errCode/errMessage（只写观测事实，不写判定词） */
  private pushErrKvs(kvs: KeyValue[], code: number, message: string): void {
    kvs.push(new KeyValue('errCode', String(code)));
    kvs.push(new KeyValue('errMessage', message));
  }

  build() {
    ProbePage({
      unitId: 'P0-U0',
      pageTitle: $r('app.string.probe_env_title'),
      steps: ENV_STEPS,
      autoStart: true,
      runStep: (stepNo: string): Promise<void> => this.runStep(stepNo)
    })
  }
}
