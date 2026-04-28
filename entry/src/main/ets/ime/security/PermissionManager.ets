import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { InputMethodExtensionContext } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';
const PERMISSION_SYNC_RETRY_COUNT = 6;
const PERMISSION_SYNC_RETRY_DELAY_MS = 120;

export class PermissionManager {
  private readonly atManager = abilityAccessCtrl.createAtManager();

  hasMicrophonePermission(context: InputMethodExtensionContext): boolean {
    try {
      return this.atManager.checkAccessTokenSync(
        context.applicationInfo.accessTokenId,
        MICROPHONE_PERMISSION
      ) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_) {
      return false;
    }
  }

  async ensureMicrophonePermission(context: InputMethodExtensionContext): Promise<boolean> {
    if (this.hasMicrophonePermission(context)) {
      return true;
    }
    let requestGranted = false;
    try {
      let result = await this.atManager.requestPermissionsFromUser(context, [MICROPHONE_PERMISSION]);
      requestGranted = this.hasGrantedAuthResult(result.authResults);
    } catch (error) {
      // 输入法扩展中 requestPermissionsFromUser 可能无法弹窗，依赖用户在系统设置或 EntryAbility 中预先授权
      hilog.error(0xFF10, 'PermissionManager', 'requestPermissionsFromUser failed: %{public}s', JSON.stringify(error));
    }
    return this.waitForMicrophonePermission(context, requestGranted);
  }

  private hasGrantedAuthResult(authResults: Array<number>): boolean {
    return authResults.some((value: number): boolean => {
      return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    });
  }

  private async waitForMicrophonePermission(context: InputMethodExtensionContext,
    fallbackGranted: boolean): Promise<boolean> {
    for (let retryIndex = 0; retryIndex < PERMISSION_SYNC_RETRY_COUNT; retryIndex++) {
      if (this.hasMicrophonePermission(context)) {
        return true;
      }
      await this.delay(PERMISSION_SYNC_RETRY_DELAY_MS);
    }
    return fallbackGranted;
  }

  private async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve): void => {
      setTimeout(resolve, milliseconds);
    });
  }
}
