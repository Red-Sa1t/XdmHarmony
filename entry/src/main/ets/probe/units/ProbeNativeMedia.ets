// P0-U4 observes the actual local-file NAPI implementation. Adjudication and
// playback/independent decoding belong to the external EXPECT/evidence workflow.
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import {
  MediaProcessorNapi, NativeMediaCapabilities, NativeMediaProgress, NativeMediaResult
} from '../../core/media/MediaProcessorNapi';

const MEDIA_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: 'NAPI 版本、架构与输入样本', autoRun: true },
  { stepNo: 'S2', title: 'H.264 + AAC 合并为 MP4', autoRun: true },
  { stepNo: 'S3', title: 'PCM 转为 MP3', autoRun: true },
  { stepNo: 'S4', title: 'MP4 不兼容时回退 Matroska', autoRun: true },
  { stepNo: 'S5', title: '失败、排队取消与运行中取消', autoRun: true },
  { stepNo: 'S6', title: '连续 20 次处理与回调清理', autoRun: true }
];
const FIXTURE_NAMES: string[] = ['video.mp4', 'audio.m4a', 'tone-44100-mono.wav'];

interface MediaProbeInput {
  name: string;
  path: string;
  bytes: number;
  sha256: string;
}

interface MediaProbeDetail {
  unit: string;
  runId: string;
  sessionToken: string;
  step: string;
  timestamp: number;
  facts: KeyValue[];
  inputs: MediaProbeInput[];
  results: NativeMediaResult[];
  capabilities: NativeMediaCapabilities;
}

@Component
export struct ProbeNativeMedia {
  private kit: ProbeKit = ProbeKit.getInstance();
  // This probe owns its queue; leaving the page cannot dispose the downloader's singleton.
  private processor: MediaProcessorNapi = new MediaProcessorNapi();
  private directory: string = '';
  // Internal session identity, independent of the HHmmss display runId.
  private preparedRun: string = '';
  private sequence: number = 0;
  private inputs: MediaProbeInput[] = [];
  private gone: boolean = false;
  private pulseTimer: number = -1;
  private pulseRun: string = '';
  private pauseTimer: number = -1;
  private pauseRun: string = '';
  private pauseResolve: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    if (this.gone) {
      this.processor = new MediaProcessorNapi();
      this.preparedRun = '';
    }
    this.gone = false;
  }

  aboutToDisappear(): void {
    this.gone = true;
    this.processor.dispose();
    this.stopPulse();
    if (this.pauseTimer >= 0) { clearTimeout(this.pauseTimer); this.pauseTimer = -1; }
    this.pauseRun = '';
    const finish: (() => void) | undefined = this.pauseResolve;
    this.pauseResolve = undefined;
    if (finish !== undefined) { finish(); }
  }

  private current(runId: string): boolean {
    return !this.gone && this.kit.isCurrent(runId);
  }

  private fresh(stem: string): string {
    this.sequence++;
    return stem + '-' + this.kit.getSessionToken() + '-' + String(this.sequence);
  }

  private async prepare(runId: string, freshSession: boolean): Promise<boolean> {
    if (!freshSession && this.preparedRun === runId && this.directory.length > 0) { return true; }
    const context = this.getUIContext().getHostContext();
    if (context === undefined || context.filesDir.length === 0) { throw new Error('Missing probe files context'); }
    const folder: string = context.filesDir + '/' + this.fresh('native-media-probe');
    fileIo.mkdirSync(folder, false);
    const copied: MediaProbeInput[] = [];
    for (let i: number = 0; i < FIXTURE_NAMES.length; i++) {
      const name: string = FIXTURE_NAMES[i];
      const bytes: Uint8Array = await context.resourceManager.getRawFileContent('native-media/' + name);
      if (!this.current(runId)) { return false; }
      const path: string = folder + '/' + name;
      this.writeFile(path, bytes.slice().buffer as ArrayBuffer);
      const fingerprint: string = await hash.hash(path, 'sha256');
      if (!this.current(runId)) { return false; }
      const input: MediaProbeInput = { name: name, path: path, bytes: bytes.length, sha256: fingerprint };
      copied.push(input);
    }
    this.directory = folder;
    this.inputs = copied;
    this.preparedRun = runId;
    return true;
  }

  private async runStep(step: string): Promise<void> {
    const runId: string = this.kit.getSessionToken();
    if (!this.current(runId)) { return; }
    try {
      const ready: boolean = await this.prepare(runId, step === 'S1');
      if (!ready || !this.current(runId)) { return; }
      if (step === 'S1') { this.runS1(runId); return; }
      if (step === 'S2') { await this.runS2(runId); return; }
      if (step === 'S3') { await this.runS3(runId); return; }
      if (step === 'S4') { await this.runS4(runId); return; }
      if (step === 'S5') { await this.runS5(runId); return; }
      if (step === 'S6') { await this.runS6(runId); return; }
    } catch (error) {
      if (!this.current(runId)) { return; }
      this.stopPulse(runId);
      const failure: BusinessError = error as BusinessError;
      this.kit.emit(step, [new KeyValue('errCode', String(failure.code ?? -1)),
        new KeyValue('errMessage', failure.message ?? 'native probe exception')]);
    }
  }

  private runS1(runId: string): void {
    const caps: NativeMediaCapabilities = this.processor.capabilities();
    this.record(runId, 'S1', [
      new KeyValue('apiVersion', String(caps.apiVersion)),
      new KeyValue('ffmpeg', caps.ffmpegVersion), new KeyValue('lame', caps.lameVersion),
      new KeyValue('abi', caps.abi), new KeyValue('mp4', String(caps.remuxMp4)),
      new KeyValue('matroska', String(caps.remuxMatroska)), new KeyValue('mp3', String(caps.encodeMp3)),
      new KeyValue('maxActiveJobs', String(caps.maxActiveJobs)), new KeyValue('inputs', String(this.inputs.length))
    ], []);
  }

  private async runS2(runId: string): Promise<void> {
    const target: string = this.directory + '/' + this.fresh('remux') + '.mp4';
    const result: NativeMediaResult = await this.processor.remux(this.fresh('p0u4-remux'),
      this.inputs[0].path, this.inputs[1].path, target);
    if (!this.current(runId)) { return; }
    const facts: KeyValue[] = this.resultFacts(result, target);
    if (result.status === 'success') {
      const fingerprint: string = await hash.hash(target, 'sha256');
      if (!this.current(runId)) { return; }
      facts.push(new KeyValue('sha256', fingerprint));
    }
    this.record(runId, 'S2', facts, [result]);
  }

  private async runS3(runId: string): Promise<void> {
    const target: string = this.directory + '/' + this.fresh('encode') + '.mp3';
    const result: NativeMediaResult = await this.processor.toMp3(this.fresh('p0u4-mp3'), this.inputs[2].path, target);
    if (!this.current(runId)) { return; }
    const facts: KeyValue[] = this.resultFacts(result, target);
    if (result.status === 'success') {
      const fingerprint: string = await hash.hash(target, 'sha256');
      if (!this.current(runId)) { return; }
      facts.push(new KeyValue('sha256', fingerprint));
    }
    this.record(runId, 'S3', facts, [result]);
  }

  private async runS4(runId: string): Promise<void> {
    const rejectedPath: string = this.directory + '/' + this.fresh('incompatible') + '.mp4';
    const first: NativeMediaResult = await this.processor.remux(this.fresh('p0u4-incompatible'),
      this.inputs[0].path, this.inputs[2].path, rejectedPath);
    if (!this.current(runId)) { return; }
    const mp4: string = this.directory + '/' + this.fresh('fallback') + '.mp4';
    const matroska: string = this.directory + '/' + this.fresh('fallback') + '.mkv';
    const fallback: NativeMediaResult = await this.processor.remuxWithFallback(this.fresh('p0u4-fallback'),
      this.inputs[0].path, this.inputs[2].path, mp4, matroska);
    if (!this.current(runId)) { return; }
    const facts: KeyValue[] = this.resultFacts(fallback, matroska);
    facts.push(new KeyValue('firstStatus', first.status));
    facts.push(new KeyValue('firstError', first.errorCode));
    facts.push(new KeyValue('rejectedExists', String(this.exists(rejectedPath))));
    facts.push(new KeyValue('fallbackMp4Exists', String(this.exists(mp4))));
    this.record(runId, 'S4', facts, [first, fallback]);
  }

  private async runS5(runId: string): Promise<void> {
    const invalid: string = this.directory + '/' + this.fresh('invalid') + '.bin';
    this.writeText(invalid, 'Deliberately invalid media fixture.');
    const missingOutput: string = this.directory + '/' + this.fresh('missing') + '.mp3';
    const missing: NativeMediaResult = await this.processor.toMp3(this.fresh('p0u4-missing'),
      this.directory + '/not-present.wav', missingOutput);
    if (!this.current(runId)) { return; }
    const invalidOutput: string = this.directory + '/' + this.fresh('invalid') + '.mp3';
    const malformed: NativeMediaResult = await this.processor.toMp3(this.fresh('p0u4-invalid'), invalid, invalidOutput);
    if (!this.current(runId)) { return; }
    const existingPath: string = this.directory + '/' + this.fresh('existing') + '.mp3';
    this.writeText(existingPath, 'The existing output belongs to somebody else.');
    const beforeExisting: string = await hash.hash(existingPath, 'sha256');
    if (!this.current(runId)) { return; }
    const existing: NativeMediaResult = await this.processor.toMp3(this.fresh('p0u4-existing'),
      this.inputs[2].path, existingPath);
    if (!this.current(runId)) { return; }
    const afterExisting: string = await hash.hash(existingPath, 'sha256');
    if (!this.current(runId)) { return; }
    const longInput: string = this.makeLongWave();
    const beforeLong: string = await hash.hash(longInput, 'sha256');
    if (!this.current(runId)) { return; }
    const activeId: string = this.fresh('p0u4-active');
    const queuedId: string = this.fresh('p0u4-queued');
    const activePath: string = this.directory + '/' + this.fresh('active-cancel') + '.mp3';
    const queuedPath: string = this.directory + '/' + this.fresh('queued-cancel') + '.mp3';
    const active: Promise<NativeMediaResult> = this.processor.toMp3(activeId, longInput, activePath);
    const queued: Promise<NativeMediaResult> = this.processor.toMp3(queuedId, this.inputs[2].path, queuedPath);
    const queuedPhase: string = this.processor.progress(queuedId).phase;
    const queuedAccepted: boolean = this.processor.cancel(queuedId);
    const queuedResult: NativeMediaResult = await queued;
    if (!this.current(runId)) { return; }
    let observed: NativeMediaProgress = this.processor.progress(activeId);
    for (let i: number = 0; i < 200 && observed.found && observed.processedTimeMs <= 0; i++) {
      await this.pause(5, runId);
      if (!this.current(runId)) { return; }
      observed = this.processor.progress(activeId);
    }
    const activeAccepted: boolean = this.processor.cancel(activeId);
    const activeResult: NativeMediaResult = await active;
    if (!this.current(runId)) { return; }
    const afterLong: string = await hash.hash(longInput, 'sha256');
    if (!this.current(runId)) { return; }
    let stable: number = 0;
    for (let i: number = 0; i < this.inputs.length; i++) {
      const fingerprint: string = await hash.hash(this.inputs[i].path, 'sha256');
      if (!this.current(runId)) { return; }
      if (fingerprint === this.inputs[i].sha256) { stable++; }
    }
    this.record(runId, 'S5', [
      new KeyValue('missingError', missing.errorCode), new KeyValue('invalidError', malformed.errorCode),
      new KeyValue('existingError', existing.errorCode), new KeyValue('existingUnchanged', String(beforeExisting === afterExisting)),
      new KeyValue('failedOutputsExist', String(this.exists(missingOutput) || this.exists(invalidOutput))),
      new KeyValue('queuedPhase', queuedPhase), new KeyValue('queuedAccepted', String(queuedAccepted)),
      new KeyValue('queuedStatus', queuedResult.status), new KeyValue('queuedOutputExists', String(this.exists(queuedPath))),
      new KeyValue('activePhase', observed.phase), new KeyValue('processedBeforeCancelMs', String(observed.processedTimeMs)),
      new KeyValue('activeAccepted', String(activeAccepted)), new KeyValue('activeStatus', activeResult.status),
      new KeyValue('activeOutputExists', String(this.exists(activePath))),
      new KeyValue('stableInputs', String(stable)), new KeyValue('longInputUnchanged', String(beforeLong === afterLong))
    ], [missing, malformed, existing, queuedResult, activeResult]);
  }

  private async runS6(runId: string): Promise<void> {
    const results: NativeMediaResult[] = [];
    let callbacks: number = 0;
    let ticks: number = 0;
    let maxGap: number = 0;
    let lastTick: number = Date.now();
    let completed: number = 0;
    this.stopPulse();
    this.pulseRun = runId;
    this.pulseTimer = setInterval((): void => {
      if (!this.current(runId)) { this.stopPulse(runId); return; }
      const now: number = Date.now();
      maxGap = Math.max(maxGap, now - lastTick);
      lastTick = now;
      ticks++;
    }, 20);
    for (let i: number = 0; i < 20; i++) {
      const target: string = this.directory + '/' + this.fresh('repeat') + '.mp3';
      const result: NativeMediaResult = await this.processor.toMp3(this.fresh('p0u4-repeat'), this.inputs[2].path,
        target, (progress: NativeMediaProgress): void => {
          if (this.current(runId)) { callbacks++; }
        });
      if (!this.current(runId)) { this.stopPulse(runId); return; }
      results.push(result);
      if (result.status === 'success') { completed++; }
    }
    const workTicks: number = ticks;
    const atCompletion: number = callbacks;
    await this.pause(1200, runId);
    if (!this.current(runId)) { this.stopPulse(runId); return; }
    this.stopPulse(runId);
    const last: NativeMediaResult = results[results.length - 1];
    this.record(runId, 'S6', [
      new KeyValue('operations', String(results.length)), new KeyValue('completed', String(completed)),
      new KeyValue('workHeartbeatTicks', String(workTicks)), new KeyValue('maxHeartbeatGapMs', String(maxGap)),
      new KeyValue('progressCallbacks', String(atCompletion)), new KeyValue('callbacksAfterCompletion', String(callbacks - atCompletion)),
      new KeyValue('lastJobFound', String(this.processor.progress(last.jobId).found)),
      new KeyValue('lateCancelAccepted', String(this.processor.cancel(last.jobId)))
    ], results);
  }

  private makeLongWave(): string {
    const source = fileIo.openSync(this.inputs[2].path, fileIo.OpenMode.READ_ONLY);
    const bytes: ArrayBuffer = new ArrayBuffer(this.inputs[2].bytes);
    try {
      const read: number = fileIo.readSync(source.fd, bytes);
      if (read !== bytes.byteLength) { throw new Error('Short fixture read'); }
    } finally { fileIo.closeSync(source); }
    const header: ArrayBuffer = bytes.slice(0, 44);
    const data: ArrayBuffer = bytes.slice(44);
    const view: DataView = new DataView(header);
    if (view.getUint32(0, true) !== 0x46464952 || view.getUint32(36, true) !== 0x61746164 ||
      view.getUint32(40, true) !== data.byteLength) { throw new Error('Unexpected synthetic WAV layout'); }
    const repeats: number = 120;
    view.setUint32(4, data.byteLength * repeats + 36, true);
    view.setUint32(40, data.byteLength * repeats, true);
    const path: string = this.directory + '/' + this.fresh('long-input') + '.wav';
    const output = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      this.writeAll(output.fd, header);
      for (let i: number = 0; i < repeats; i++) { this.writeAll(output.fd, data); }
    } finally { fileIo.closeSync(output); }
    return path;
  }

  private resultFacts(result: NativeMediaResult, path: string): KeyValue[] {
    return [new KeyValue('status', result.status), new KeyValue('error', result.errorCode),
      new KeyValue('format', result.format), new KeyValue('reportedBytes', String(result.outputBytes)),
      new KeyValue('fileBytes', String(this.exists(path) ? fileIo.statSync(path).size : 0)),
      new KeyValue('durationMs', String(result.durationMs))];
  }

  private record(runId: string, step: string, facts: KeyValue[], results: NativeMediaResult[]): void {
    if (!this.current(runId)) { return; }
    const detail: MediaProbeDetail = {
      unit: 'P0-U4', runId: this.kit.getRunId(), sessionToken: runId,
      step: step, timestamp: Date.now(), facts: facts,
      inputs: this.inputs, results: results, capabilities: this.processor.capabilities()
    };
    const path: string = this.directory + '/' + this.fresh(step + '-details') + '.json';
    this.writeText(path, JSON.stringify(detail, null, 2));
    const emitted: KeyValue[] = facts.slice();
    emitted.push(new KeyValue('detailFile', path));
    if (this.current(runId)) { this.kit.emit(step, emitted); }
  }

  private exists(path: string): boolean {
    try { return fileIo.accessSync(path); } catch (_) { return false; }
  }

  private writeText(path: string, text: string): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
      this.writeAll(file.fd, bytes.buffer as ArrayBuffer);
    } finally { fileIo.closeSync(file); }
  }

  private writeFile(path: string, buffer: ArrayBuffer): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try { this.writeAll(file.fd, buffer); } finally { fileIo.closeSync(file); }
  }

  private writeAll(fd: number, buffer: ArrayBuffer): void {
    let written: number = 0;
    while (written < buffer.byteLength) {
      const count: number = fileIo.writeSync(fd, buffer.slice(written));
      if (count <= 0) { throw new Error('Short probe fixture write'); }
      written += count;
    }
  }

  private pause(milliseconds: number, runId: string): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.pauseResolve = resolve;
      this.pauseRun = runId;
      const timer: number = setTimeout((): void => {
        if (this.pauseRun === runId && this.pauseTimer === timer) {
          this.pauseTimer = -1;
          this.pauseRun = '';
          this.pauseResolve = undefined;
        }
        resolve();
      }, milliseconds);
      this.pauseTimer = timer;
    });
  }

  private stopPulse(runId: string = ''): void {
    if (runId.length > 0 && this.pulseRun !== runId) { return; }
    if (this.pulseTimer >= 0) { clearInterval(this.pulseTimer); this.pulseTimer = -1; }
    this.pulseRun = '';
  }

  build() {
    ProbePage({ unitId: 'P0-U4', pageTitle: $r('app.string.probe_p0u4_title'), steps: MEDIA_STEPS,
      runStep: (step: string): Promise<void> => this.runStep(step) })
  }
}
