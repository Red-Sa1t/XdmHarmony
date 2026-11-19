/*
 * U0.1 探针基建：探针首页（@Entry）。
 * 探针单元注册表 PROBE_UNITS：点击卡片页内条件渲染切换单元视图（不新增路由页），
 * 返回按钮回列表；后续单元在此追加 PROBE_UNITS 表项与 else-if 分支。
 * 拉起方式：aa start --ps page probe（EntryAbility want 参数路由）；探针子页不注册 main_pages。
 * U0.3 只加不改：表尾追加 P0-U3（扩展桥 8597 服务端探针，Phase 0 谱系回补）与 ProbeBridge 分支。
 * U6.1 只加不改：表尾追加 P6-U1（扩展桥八路由完整版探针）与 ProbeBridgeRoutes 分支。
 * U6.2 只加不改：表尾追加 P6-U2（嗅探规则链+视频捕获探针）与 ProbeVideoSniff 分支。
 * U7.1 只加不改：表尾追加 P7-U1-F/P/P（DASH 解析/管线/运行控制三件套）与三分支。
 */

import { ProbeEnv } from './units/ProbeEnv';
import { ProbeHttp } from './units/ProbeHttp';
import { ProbeStore } from './units/ProbeStore';
import { ProbeDownload } from './units/ProbeDownload';
import { ProbeSegment } from './units/ProbeSegment';
import { ProbeResume } from './units/ProbeResume';
import { ProbeQueue } from './units/ProbeQueue';
import { ProbeSpeedLimit } from './units/ProbeSpeedLimit';
import { ProbeMainWindow } from './units/ProbeMainWindow';
import { ProbeDialogs } from './units/ProbeDialogs';
import { ProbeSettings } from './units/ProbeSettings';
import { ProbeBackgroundNotify } from './units/ProbeBackgroundNotify';
import { ProbeClipboardSaveDir } from './units/ProbeClipboardSaveDir';
import { ProbeBridge } from './units/ProbeBridge';
import { ProbeBridgeRoutes } from './units/ProbeBridgeRoutes';
import { ProbeVideoSniff } from './units/ProbeVideoSniff';
import { ProbeLinkRefresh } from './units/ProbeLinkRefresh';
import { ProbeNativeMedia } from './units/ProbeNativeMedia';
import { ProbeAdaptiveFoundation } from './units/ProbeAdaptiveFoundation';
import { ProbeAdaptivePipeline } from './units/ProbeAdaptivePipeline';
import { ProbeAdaptiveController } from './units/ProbeAdaptiveController';
import { ProbeDashFoundation } from './units/ProbeDashFoundation';
import { ProbeDashPipeline } from './units/ProbeDashPipeline';
import { ProbeDashController } from './units/ProbeDashController';

interface ProbeUnitEntry {
  unitId: string;
  title: ResourceStr;
}

const PROBE_UNITS: ProbeUnitEntry[] = [
  { unitId: 'P0-U0', title: $r('app.string.probe_env_title') },
  { unitId: 'P0-U2', title: $r('app.string.probe_http_title') },
  { unitId: 'P1-U1', title: $r('app.string.probe_p1u1_title') },
  { unitId: 'P1-U2', title: $r('app.string.probe_p1u2_title') },
  { unitId: 'P2-U1', title: $r('app.string.probe_p2u1_title') },
  { unitId: 'P2-U2', title: $r('app.string.probe_p2u2_title') },
  { unitId: 'P3-U1', title: $r('app.string.probe_p3u1_title') },
  { unitId: 'P3-U2', title: $r('app.string.probe_p3u2_title') },
  { unitId: 'P4-U1', title: $r('app.string.probe_p4u1_title') },
  { unitId: 'P4-U2', title: $r('app.string.probe_p4u2_title') },
  { unitId: 'P4-U3', title: $r('app.string.probe_p4u3_title') },
  { unitId: 'P5-U1', title: $r('app.string.probe_p5u1_title') },
  { unitId: 'P5-U2', title: $r('app.string.probe_p5u2_title') },
  { unitId: 'P0-U3', title: $r('app.string.probe_p0u3_title') },
  { unitId: 'P6-U1', title: $r('app.string.probe_p6u1_title') },
  { unitId: 'P6-U2', title: $r('app.string.probe_p6u2_title') },
  { unitId: 'P6-U3', title: $r('app.string.probe_p6u3_title') },
  { unitId: 'P0-U4', title: $r('app.string.probe_p0u4_title') },
  { unitId: 'P6-U4', title: $r('app.string.probe_p6u4_title') },
  { unitId: 'P6-U5', title: $r('app.string.probe_p6u5_title') },
  { unitId: 'P6-U6', title: $r('app.string.probe_p6u6_title') },
  { unitId: 'P7-U1-F', title: $r('app.string.probe_p7u1_foundation_title') },
  { unitId: 'P7-U1-P', title: $r('app.string.probe_p7u1_pipeline_title') },
  { unitId: 'P7-U1-C', title: $r('app.string.probe_p7u1_controller_title') }
];

@Entry
@Component
struct ProbeIndex {
  @State selectedUnitId: string = '';

  private currentUnitTitle(): ResourceStr {
    const selected: string = this.selectedUnitId;
    for (let i = 0; i < PROBE_UNITS.length; i++) {
      if (PROBE_UNITS[i].unitId === selected) {
        return PROBE_UNITS[i].title;
      }
    }
    return $r('app.string.probe_index_title');
  }

  build() {
    Column() {
      if (this.selectedUnitId === '') {
        Text($r('app.string.probe_index_title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 24, bottom: 16 })
        if (PROBE_UNITS.length === 0) {
          Text($r('app.string.probe_index_empty'))
            .fontSize(14)
            .opacity(0.6)
        }
        Scroll() {
          Column() {
            ForEach(PROBE_UNITS, (entry: ProbeUnitEntry) => {
              Row({ space: 12 }) {
                Text(entry.unitId).fontSize(14).fontWeight(FontWeight.Medium)
                Text(entry.title).fontSize(14).opacity(0.8).layoutWeight(1)
                Text('>').fontSize(16).opacity(0.4)
              }
              .width('92%').padding(14).borderRadius(12).backgroundColor('#F1F3F5')
              .onClick(() => { this.selectedUnitId = entry.unitId; })
            }, (entry: ProbeUnitEntry) => entry.unitId)
          }.width('100%')
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      } else {
        Row({ space: 8 }) {
          Button($r('app.string.probe_back'))
            .onClick(() => {
              this.selectedUnitId = '';
            })
          Text(this.currentUnitTitle())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        Column() {
          if (this.selectedUnitId === 'P0-U0') {
            ProbeEnv()
          } else if (this.selectedUnitId === 'P0-U2') {
            ProbeHttp()
          } else if (this.selectedUnitId === 'P1-U1') {
            ProbeStore()
          } else if (this.selectedUnitId === 'P1-U2') {
            ProbeDownload()
          } else if (this.selectedUnitId === 'P2-U1') {
            ProbeSegment()
          } else if (this.selectedUnitId === 'P2-U2') {
            ProbeResume()
          } else if (this.selectedUnitId === 'P3-U1') {
            ProbeQueue()
          } else if (this.selectedUnitId === 'P3-U2') {
            ProbeSpeedLimit()
          } else if (this.selectedUnitId === 'P4-U1') {
            ProbeMainWindow()
          } else if (this.selectedUnitId === 'P4-U2') {
            ProbeDialogs()
          } else if (this.selectedUnitId === 'P4-U3') {
            ProbeSettings()
          } else if (this.selectedUnitId === 'P5-U1') {
            ProbeBackgroundNotify()
          } else if (this.selectedUnitId === 'P5-U2') {
            ProbeClipboardSaveDir()
          } else if (this.selectedUnitId === 'P0-U3') {
            ProbeBridge()
          } else if (this.selectedUnitId === 'P6-U1') {
            ProbeBridgeRoutes()
          } else if (this.selectedUnitId === 'P6-U2') {
            ProbeVideoSniff()
          } else if (this.selectedUnitId === 'P6-U3') {
            ProbeLinkRefresh()
          } else if (this.selectedUnitId === 'P0-U4') {
            ProbeNativeMedia()
          } else if (this.selectedUnitId === 'P6-U4') {
            ProbeAdaptiveFoundation()
          } else if (this.selectedUnitId === 'P6-U5') {
            ProbeAdaptivePipeline()
          } else if (this.selectedUnitId === 'P6-U6') {
            ProbeAdaptiveController()
          } else if (this.selectedUnitId === 'P7-U1-F') {
            ProbeDashFoundation()
          } else if (this.selectedUnitId === 'P7-U1-P') {
            ProbeDashPipeline()
          } else if (this.selectedUnitId === 'P7-U1-C') {
            ProbeDashController()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }
}
