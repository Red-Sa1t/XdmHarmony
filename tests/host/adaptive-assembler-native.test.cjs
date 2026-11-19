'use strict';
// Opt-in: reuse a compiled host version of the real production C++ core, without rebuilding it.
// Windows callers supply XDM_ASSEMBLY_NATIVE_RUNNER as a WSL Ubuntu absolute executable path.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { test } = require('node:test');
const { fixture } = require('./adaptive-assembler-harness.cjs');
const run = promisify(execFile);
const RUNNER = process.env.XDM_ASSEMBLY_NATIVE_RUNNER;
const FFPROBE = process.env.XDM_ASSEMBLY_FFPROBE || 'ffprobe';
const FFMPEG = process.env.XDM_ASSEMBLY_FFMPEG || 'ffmpeg';
const EVIDENCE = process.env.XDM_ASSEMBLY_EVIDENCE_DIRECTORY;
const RAW = path.resolve(__dirname, '../../entry/src/main/resources/rawfile/native-media');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function linuxPath(value) {
  const absolute = path.resolve(value);
  if (process.platform !== 'win32') return absolute;
  assert.match(absolute, /^[A-Za-z]:\\/);
  return '/mnt/' + absolute[0].toLowerCase() + absolute.substring(2).replaceAll('\\', '/');
}
async function execute(binary, args) {
  const result = process.platform === 'win32' ? await run('wsl.exe', ['-d', 'Ubuntu', '--', binary, ...args],
    { windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 }) : await run(binary, args,
    { timeout: 30000, maxBuffer: 1024 * 1024 });
  assert.equal(result.stderr, '', 'native/decoder stderr must be inspected, not hidden');
  return result.stdout;
}

for (const containerCase of ['mp4', 'matroska-fallback']) {
  test('F actual native assembly and independent decode: ' + containerCase, { skip: !RUNNER }, async t => {
    const f = await fixture(t);
    const video = await fs.readFile(path.join(RAW, 'video.mp4'));
    const audio = await fs.readFile(path.join(RAW, containerCase === 'mp4' ? 'audio.m4a' : 'tone-44100-mono.wav'));
    const videoSplit = Math.floor(video.length / 3); const audioSplit = Math.floor(audio.length / 2);
    // Plan representation names choose the existing mp4-then-mkv policy; native demuxes actual bytes.
    const state = await f.complete([video.subarray(0, videoSplit), video.subarray(videoSplit)],
      [audio.subarray(0, audioSplit), audio.subarray(audioSplit)], ['mp4', 'm4a']);
    for (const part of state.parts) await fs.appendFile(f.file(part.fileName), 'UNCOMMITTED_TAIL');
    const calls = [];
    f.setNative(async call => {
      const actualOutput = linuxPath(f.adapter.real(call.output));
      const args = ['remux', call.id, linuxPath(f.adapter.real(call.video)), linuxPath(f.adapter.real(call.audio)), actualOutput, call.format];
      let stdout; let exit = 0;
      try { stdout = await execute(RUNNER, args); }
      catch (error) {
        if (error.code !== 2 || error.stderr !== '') throw error;
        stdout = error.stdout; exit = error.code;
      }
      const observed = JSON.parse(stdout); calls.push({ args, exit, observed });
      assert.equal(digest(await fs.readFile(f.adapter.real(call.video))), digest(video));
      assert.equal(digest(await fs.readFile(f.adapter.real(call.audio))), digest(audio));
      return { ...observed, outputPath: observed.outputPath === actualOutput ? call.output : observed.outputPath };
    });
    const started = Date.now(); const result = await f.assembler().run(state);
    assert.equal(result.status, 'success'); assert.equal(result.closed, true); assert.equal(result.resourceUncertain, false);
    assert.equal(result.cleanupComplete, true); assert.equal(result.mediaStarted, true); assert.equal(result.mediaSettled, true);
    assert.equal(result.extension, containerCase === 'mp4' ? '.mp4' : '.mkv');
    assert.equal(calls.length, containerCase === 'mp4' ? 1 : 2);
    if (containerCase !== 'mp4') assert.ok(['UNSUPPORTED_STREAM', 'INVALID_DATA'].includes(calls[0].observed.errorCode));
    const finalPath = f.file(result.outputName); const output = await fs.readFile(finalPath);
    assert.equal(output.length, result.outputBytes);
    const probe = JSON.parse(await execute(FFPROBE, ['-v', 'error', '-show_entries',
      'stream=codec_name,codec_type:format=format_name,duration,size', '-of', 'json', linuxPath(finalPath)]));
    assert.equal(probe.streams.filter(s => s.codec_type === 'video').length, 1);
    assert.equal(probe.streams.filter(s => s.codec_type === 'audio').length, 1);
    await execute(FFMPEG, ['-nostdin', '-v', 'error', '-threads', '1', '-filter_threads', '1',
      '-i', linuxPath(finalPath), '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-']);
    const evidence = { scope: 'Production ArkTS assembler/E2/media queue over real host FS + production host C++ core; not OHOS runtime',
      containerCase, elapsedMs: Date.now() - started, result, calls, ffprobe: probe,
      tools: { runner: RUNNER, ffprobe: FFPROBE, ffmpeg: FFMPEG },
      inputs: { videoBytes: video.length, videoSha256: digest(video), audioBytes: audio.length, audioSha256: digest(audio) },
      outputBytes: output.length, outputSha256: digest(output), independentDecodeExit: 0, stderrEmpty: true };
    if (EVIDENCE) {
      const directory = path.resolve(EVIDENCE); await fs.mkdir(directory, { recursive: true });
      await fs.copyFile(finalPath, path.join(directory, containerCase + result.extension), nativeFsCopyExclusive());
      await fs.writeFile(path.join(directory, containerCase + '.json'), JSON.stringify(evidence, null, 2), { flag: 'wx' });
    }
    t.diagnostic(JSON.stringify({ containerCase, outputBytes: output.length, sha256: digest(output), actualNativeCalls: calls.length }));
  });
}

function nativeFsCopyExclusive() { return require('node:fs').constants.COPYFILE_EXCL; }
