import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { InputMethodExtensionContext } from '@kit.IMEKit';

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
        if (result.authResults[index] === 0) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return this.hasMicrophonePermission(context);
  }
}
