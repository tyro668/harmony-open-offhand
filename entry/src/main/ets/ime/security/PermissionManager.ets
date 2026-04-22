import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { InputMethodExtensionContext } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';

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
    try {
      let result = await this.atManager.requestPermissionsFromUser(context, [MICROPHONE_PERMISSION]);
      for (let index = 0; index < result.authResults.length; index++) {
        if (result.authResults[index] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      }
    } catch (error) {
      // 输入法扩展中 requestPermissionsFromUser 可能无法弹窗，依赖用户在系统设置或 EntryAbility 中预先授权
      hilog.error(0xFF10, 'PermissionManager', 'requestPermissionsFromUser failed: %{public}s', JSON.stringify(error));
      return false;
    }
    return this.hasMicrophonePermission(context);
  }
}
