/** Pure HLS metadata. Parsing does not imply encrypted media or assembly is supported. */
export type HlsAttributes = Record<string, string>;
export type HlsUrlResolver = (base: string, reference: string) => string;
export const HLS_MAX_URL_CHARS: number = 32768;

export class HlsByteRange {
  offset: number = 0;
  length: number = 0;
}

export class HlsMediaSegment {
  url: string = '';
  byteRange: HlsByteRange | null = null;
  duration: number = 0;
  sequence: number = 0;
  isInit: boolean = false;
  keyUrl: string | null = null;
  iv: string | null = null;
  discontinuity: boolean = false;
  discontinuitySequence: number = 0;
}

export class HlsPlaylist {
  segments: HlsMediaSegment[] = [];
  totalDuration: number = 0;
  hasByteRange: boolean = false;
  isEncrypted: boolean = false;
  isKeyIFrameOnly: boolean = false;
  mediaSequence: number = 0;
  discontinuitySequence: number = 0;
  endList: boolean = false;
}

export class HlsPlaylistContainer {
  videoPlaylist: string | null = null;
  audioPlaylist: string | null = null;
  attributes: HlsAttributes = {};
}
