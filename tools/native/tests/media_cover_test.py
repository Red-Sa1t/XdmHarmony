#!/usr/bin/env python3
"""Targeted real-media cover/chapters regressions. Pillow is a host-fixture dependency only."""
import argparse
import hashlib
import json
import pathlib
import re
import struct
import subprocess
import zlib

import PIL
from PIL import Image


def sha(data):
    return hashlib.sha256(data).hexdigest()


def syncsafe(value):
    return bytes((value >> shift) & 127 for shift in (21, 14, 7, 0))


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def decorate_mp3(audio, pictures):
    if audio[:3] == b'ID3':
        length = sum(audio[6 + index] << shift for index, shift in enumerate((21, 14, 7, 0)))
        audio = audio[10 + length:]
    frames = b''
    for index, (mime, picture) in enumerate(pictures):
        payload = b'\x00' + mime.encode('ascii') + b'\x00' + bytes([3 if index == 0 else 0]) + b'\x00' + picture
        frames += b'APIC' + struct.pack('>I', len(payload)) + b'\x00\x00' + payload
    return b'ID3\x03\x00\x00' + syncsafe(len(frames)) + frames + audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', type=pathlib.Path, required=True)
    parser.add_argument('--fixtures', type=pathlib.Path, required=True)
    parser.add_argument('--original-cover-dir', type=pathlib.Path, required=True)
    parser.add_argument('--ffmpeg', type=pathlib.Path, required=True)
    parser.add_argument('--ffprobe', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--sanitizer-subset', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixtures = args.fixtures.resolve()
    original = args.original_cover_dir.resolve()
    original_hashes = {path: sha(path.read_bytes()) for path in original.iterdir() if path.is_file()}
    entries = []
    commands = []

    def run(command, input=None):
        proc = subprocess.run([str(arg) for arg in command], input=input, capture_output=True, timeout=40)
        stderr = proc.stderr.decode('utf-8', errors='replace')
        commands.append({'argv': [str(arg) for arg in command], 'exit': proc.returncode, 'stderr': stderr})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        assert not re.search(r'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:', stderr), stderr
        return proc

    def ffmpeg(arguments):
        proc = run([args.ffmpeg, '-nostdin', '-v', 'error', '-threads', '1', '-filter_threads', '1',
                    '-filter_complex_threads', '1', *arguments])
        assert proc.returncode == 0, proc.stderr.decode()
        return proc.stdout

    def probe(path):
        proc = run([args.ffprobe, '-v', 'error', '-show_streams', '-show_chapters', '-of', 'json', path])
        assert proc.returncode == 0, proc.stderr.decode()
        return json.loads(proc.stdout)

    def audio(path):
        return ffmpeg(['-i', path, '-map', '0:a:0', '-f', 'f32le', '-c:a', 'pcm_f32le', '-'])

    def audio_packets(path):
        return ffmpeg(['-i', path, '-map', '0:a:0', '-c:a', 'copy', '-f', 'data', '-'])

    def picture(path, index=0):
        return ffmpeg(['-i', path, '-map', '0:v:' + str(index), '-frames:v', '1', '-c:v', 'copy', '-f', 'image2pipe', '-'])

    def pixels(data):
        proc = run([args.ffmpeg, '-nostdin', '-v', 'error', '-threads', '1', '-filter_threads', '1',
                    '-i', 'pipe:0', '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], input=data)
        assert proc.returncode == 0 and proc.stdout, proc.stderr.decode()
        return proc.stdout

    def record(name, result, extra):
        entries.append({'case': name, 'result': result, **extra})
        (output / 'results.json').write_text(json.dumps({'scope': 'Host-only actual media/header regression',
            'pillow': PIL.__version__, 'sanitizerSubset': args.sanitizer_subset, 'checks': entries}, indent=2) + '\n')
        print(json.dumps({'case': name, 'checked': True}), flush=True)

    def convert(name, source, expected=None, warning=None, audio_reference=None):
        destination = output / (name + '.mp3')
        before = sha(source.read_bytes())
        proc = run([args.runner, 'mp3', name, source, destination])
        assert proc.returncode == 0, proc.stdout.decode() + proc.stderr.decode()
        result = json.loads(proc.stdout)
        assert result['status'] == 'success' and result['outputBytes'] == destination.stat().st_size
        assert sha(source.read_bytes()) == before
        if warning:
            assert warning in result['warnings'], result
        else:
            assert result['warnings'] == [], result
        inspected = probe(destination)
        images = [stream for stream in inspected['streams'] if stream['codec_type'] == 'video']
        details = {'inputSha256': before, 'outputSha256': sha(destination.read_bytes()), 'images': len(images)}
        if expected is not None:
            assert len(images) == 1
            extracted = picture(destination)
            assert extracted == expected
            decoded = pixels(extracted)
            assert decoded == pixels(expected)
            details.update({'coverPacketSha256': sha(extracted), 'decodedPixelSha256': sha(decoded)})
        else:
            assert images == []
        if audio_reference is not None:
            assert audio(destination) == audio_reference, name + ' changed audio relative to undecorated input'
            details['decodedAudioEqualsUndecorated'] = True
        if warning == 'CHAPTERS_NOT_COPIED':
            assert len(probe(source)['chapters']) == 2 and inspected['chapters'] == []
        record(name, result, details)
        return destination

    image = Image.new('RGB', (64, 64))
    image.putdata([((i * 53) % 256, (i * 29) % 256, (i * 97) % 256) for i in range(4096)])
    images = {}
    for name, settings in [('baseline', {}), ('progressive', {'progressive': True}),
                           ('restart', {'restart_marker_blocks': 1})]:
        path = output / (name + '.jpg')
        image.save(path, format='JPEG', quality=91, **settings)
        images[name] = path.read_bytes()
    assert images['progressive'].count(b'\xff\xda') > 1
    assert b'\xff\x00' in images['restart']
    assert sum(images['restart'].count(bytes([255, value])) for value in range(208, 216)) > 0
    png = (original / 'cover.png').read_bytes()
    palette_file = output / 'palette.png'
    image.convert('P').save(palette_file, format='PNG')
    images['palette'] = palette_file.read_bytes()
    bmp_file = output / 'unsupported.bmp'
    image.save(bmp_file, format='BMP')
    plain_source = output / 'plain-source.mp3'
    ffmpeg(['-i', fixtures / 'audio.m4a', '-acodec', 'libmp3lame', '-threads', '1', plain_source])
    plain_mp3 = convert('plain-mp3-control', plain_source)
    reference_audio = audio(plain_mp3)
    plain_aac = convert('plain-aac-control', fixtures / 'audio.m4a')
    reference_aac = audio(plain_aac)

    for name, payload in [('png', png), *images.items()]:
        mime = 'image/png' if name in ('png', 'palette') else 'image/jpeg'
        source = output / (name + '-input.mp3')
        source.write_bytes(decorate_mp3(plain_source.read_bytes(), [(mime, payload)]))
        convert(name + '-mp3', source, payload, audio_reference=reference_audio)

    # Preserve the independent review's original bytes and replay both formats.
    convert('original-png-m4a', original / 'with-cover.m4a', png, audio_reference=reference_aac)
    convert('original-png-mp3', original / 'with-cover.mp3', png)
    convert('original-chapters', original / 'with-chapters.m4a', warning='CHAPTERS_NOT_COPIED', audio_reference=reference_aac)

    bad_crc = bytearray(png)
    bad_crc[-1] ^= 1
    huge_header = struct.pack('>IIBBBBB', 0xffffffff, 2, 8, 2, 0, 0, 0)
    malformed = {
        'png-crc': bytes(bad_crc), 'png-truncated': png[:-5],
        'png-first-chunk': png[:8] + png_chunk(b'tEXt', b'n=v') + png[8:],
        'png-no-idat': png[:33] + png_chunk(b'IEND', b''), 'png-no-iend': png[:-12],
        'png-huge-length': png[:8] + b'\xff\xff\xff\xff' + png[12:],
        'png-huge-dimensions': png[:8] + png_chunk(b'IHDR', huge_header) + png[33:],
        'jpeg-no-eoi': images['baseline'][:-2], 'jpeg-truncated-marker': b'\xff\xd8\xff',
    }
    bad_sof = bytearray(images['baseline'])
    sof = bad_sof.index(b'\xff\xc0')
    bad_sof[sof + 2:sof + 4] = b'\x00\x01'
    malformed['jpeg-sof-length'] = bytes(bad_sof)
    for name, payload in malformed.items():
        mime = 'image/png' if name.startswith('png') else 'image/jpeg'
        source = output / (name + '-input.mp3')
        source.write_bytes(decorate_mp3(plain_source.read_bytes(), [(mime, payload)]))
        convert(name, source, warning='INVALID_COVER_ART', audio_reference=reference_audio)
    unsupported = output / 'bmp-input.mp3'
    unsupported.write_bytes(decorate_mp3(plain_source.read_bytes(), [('image/bmp', bmp_file.read_bytes())]))
    convert('unsupported-bmp', unsupported, warning='UNSUPPORTED_COVER_ART', audio_reference=reference_audio)

    if not args.sanitizer_subset:
        for name in ('baseline', 'progressive'):
            source = output / (name + '-input.m4a')
            ffmpeg(['-i', fixtures / 'audio.m4a', '-i', output / (name + '.jpg'), '-map', '0:a', '-map', '1:v',
                    '-c', 'copy', '-disposition:v', 'attached_pic', source])
            convert(name + '-m4a', source, images[name], audio_reference=reference_aac)
        selected = output / 'multiple-input.mp3'
        selected.write_bytes(decorate_mp3(plain_source.read_bytes(), [('image/png', png), ('image/jpeg', images['baseline'])]))
        assert len([s for s in probe(selected)['streams'] if s['codec_type'] == 'video']) == 2
        convert('largest-cover-selected', selected, images['baseline'], audio_reference=reference_audio)

    remux_inputs = [('png', original / 'with-cover.m4a', png)]
    if not args.sanitizer_subset:
        remux_inputs.append(('jpeg', output / 'progressive-input.m4a', images['progressive']))
    for label, source, expected in remux_inputs:
        for container in ('mp4', 'matroska'):
            name = label + '-remux-' + container
            destination = output / (name + '.part')
            proc = run([args.runner, 'remux', name, fixtures / 'video.mp4', source, destination, container])
            assert proc.returncode == 0, proc.stdout.decode() + proc.stderr.decode()
            result = json.loads(proc.stdout)
            assert result['status'] == 'success'
            codecs = [stream['codec_name'] for stream in probe(destination)['streams']]
            assert codecs == ['h264', 'aac', 'png' if label == 'png' else 'mjpeg'], codecs
            extracted = picture(destination, 1)
            assert extracted == expected and pixels(extracted) == pixels(expected)
            reference = output / (name + '-cli-reference.part')
            ffmpeg(['-i', fixtures / 'video.mp4', '-i', source, '-acodec', 'copy', '-vcodec', 'copy',
                    '-map', '0', '-map', '1', '-f', container, reference])
            source_pcm = audio(source)
            copied_pcm = audio(destination)
            reference_pcm = audio(reference)
            # Matroska does not carry this M4A's AAC priming skip. The original CLI
            # command has the same decoded prefix; compare to it without hiding
            # the sample delta against the input. MP4 retains input-PCM equality.
            assert copied_pcm == reference_pcm, name + ' differs from original FFmpeg command'
            if container == 'mp4':
                assert copied_pcm == source_pcm
            source_packets = audio_packets(source)
            assert audio_packets(destination) == source_packets
            channels = next(stream['channels'] for stream in probe(source)['streams'] if stream['codec_type'] == 'audio')
            frame_bytes = 4 * channels
            assert len(source_pcm) % frame_bytes == 0 and len(copied_pcm) % frame_bytes == 0
            record(name, result, {'codecs': codecs, 'coverPacketSha256': sha(extracted),
                'copiedAudioPacketSha256': sha(source_packets), 'copiedAudioPacketsEqualInput': True,
                'decodedAudioEqualsOriginalCli': True, 'decodedAudioSha256': sha(copied_pcm),
                'decodedAudioEqualsInput': copied_pcm == source_pcm,
                'inputDecodedFrames': len(source_pcm) // frame_bytes,
                'outputDecodedFrames': len(copied_pcm) // frame_bytes,
                'decodedFrameDeltaFromInput': (len(copied_pcm) - len(source_pcm)) // frame_bytes})

    for container, expected_exit in [('mp4', 2), ('matroska', 0)]:
        destination = output / ('pcm-fallback-' + container + '.part')
        proc = run([args.runner, 'remux', 'pcm-' + container, fixtures / 'video.mp4',
                    fixtures / 'tone-44100-mono.wav', destination, container])
        assert proc.returncode == expected_exit, proc.stdout.decode()
        result = json.loads(proc.stdout)
        assert result['errorCode'] == ('UNSUPPORTED_STREAM' if container == 'mp4' else 'NONE')
        assert destination.exists() == (container == 'matroska')
        record('pcm-fallback-' + container, result, {})
    for path, fingerprint in original_hashes.items():
        assert sha(path.read_bytes()) == fingerprint, 'Independent original fixture changed'
    print(json.dumps({'checks': len(entries), 'output': str(output), 'originalFixturesUnchanged': True}), flush=True)


if __name__ == '__main__':
    main()
