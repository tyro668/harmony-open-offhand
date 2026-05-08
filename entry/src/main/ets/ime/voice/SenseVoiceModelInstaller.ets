import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OffhandLocalAsrConfig } from '../common/ImeTypes';

const DOMAIN = 0xFF10;
const TAG = 'SenseVoiceInstaller';

export const SENSEVOICE_RAW_MODEL_ROOT = 'asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';
export const SENSEVOICE_VAD_MODEL_PATH = 'asr/silero_vad.onnx';

const REQUIRED_RAW_FILES: string[] = [
  `${SENSEVOICE_RAW_MODEL_ROOT}/model.int8.onnx`,
  `${SENSEVOICE_RAW_MODEL_ROOT}/tokens.txt`,
  SENSEVOICE_VAD_MODEL_PATH
];

interface RawFdDescriptor {
  fd: number;
  offset: number;
  length: number;
}

export interface SenseVoiceModelPaths {
  modelDir: string;
  modelPath: string;
  tokensPath: string;
  vadModelPath: string;
  resourceManager?: Object;
}

export class SenseVoiceModelInstaller {
  async ensureReady(context: common.Context, localConfig: OffhandLocalAsrConfig): Promise<SenseVoiceModelPaths | undefined> {
    if (typeof localConfig.modelId === 'string' && localConfig.modelId.length > 0 &&
      localConfig.modelId !== 'sense-voice-zh-en-ja-ko-yue-2024-07-17-int8') {
      hilog.warn(DOMAIN, TAG, 'unexpected local ASR modelId: %{public}s', localConfig.modelId);
    }

    for (let index = 0; index < REQUIRED_RAW_FILES.length; index++) {
      let rawPath = REQUIRED_RAW_FILES[index];
      let descriptor: RawFdDescriptor | undefined = undefined;
      try {
        descriptor = await context.resourceManager.getRawFd(rawPath) as RawFdDescriptor;
        if (descriptor.length <= 0) {
          hilog.warn(DOMAIN, TAG, 'raw model file is empty: %{public}s', rawPath);
          return undefined;
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'raw model file unavailable: %{public}s %{public}s',
          rawPath, (error as Error).message ?? String(error));
        return undefined;
      } finally {
        if (descriptor) {
          try {
            await context.resourceManager.closeRawFd(rawPath);
          } catch (_) {
          }
        }
      }
    }

    return {
      modelDir: SENSEVOICE_RAW_MODEL_ROOT,
      modelPath: `${SENSEVOICE_RAW_MODEL_ROOT}/model.int8.onnx`,
      tokensPath: `${SENSEVOICE_RAW_MODEL_ROOT}/tokens.txt`,
      vadModelPath: SENSEVOICE_VAD_MODEL_PATH,
      resourceManager: context.resourceManager as Object
    };
  }
}
