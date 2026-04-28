import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getEntryAbilityContext } from '../entryability/AbilityContextStore';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';

const PAGE_BACKGROUND = '#FFFFFF';
const PRIMARY_BLUE = '#1976F3';
const SUCCESS_GREEN = '#19A79C';
const ERROR_ORANGE = '#C46B29';
const TEXT_PRIMARY = '#121826';
const TEXT_SECONDARY = '#667085';
const DIVIDER_COLOR = '#F0F2F5';
const PERMISSION_SYNC_RETRY_COUNT = 6;
const PERMISSION_SYNC_RETRY_DELAY_MS = 120;
const PERMISSION_LOG_DOMAIN = 0x0001;
const PERMISSION_LOG_TAG = 'OffhandPermission';

@Entry
@Component
struct Index {
  @State private microphonePermissionStatus: string = '检查中';
  @State private microphonePermissionGranted: boolean = false;
  private readonly atManager = abilityAccessCtrl.createAtManager();
  private abilityContext?: common.UIAbilityContext;
  private cachedTokenId: number = 0;
  private permissionListenerRegistered: boolean = false;

  aboutToAppear(): void {
    void this.registerPermissionStateListener();
    void this.refreshMicrophonePermissionStatus();
  }

  onPageShow(): void {
    void this.refreshMicrophonePermissionStatus();
  }

  aboutToDisappear(): void {
    this.unregisterPermissionStateListener();
  }

  build() {
    Column() {
      this.renderHeader()
      this.renderDivider()
      this.renderEntrySection()
      this.renderDivider()
      this.renderPermissionSection()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
    .padding({ left: 20, right: 20, top: 28 })
  }

  @Builder
  private renderHeader() {
    Row() {
      Text('配置')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
    }
    .width('100%')
    .padding({ bottom: 20 })
  }

  @Builder
  private renderDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(DIVIDER_COLOR)
      .width('100%')
  }

  @Builder
  private renderEntrySection() {
    Column({ space: 16 }) {
      Text('输入法内配置')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ top: 20 })

      this.renderKeyboardIllustration()

      Text('在键盘左上角打开配置。')
        .fontSize(14)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ bottom: 20 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderKeyboardIllustration() {
    Column({ space: 3 }) {
      Row() {
        Column() {
          Image($r('app.media.ime_icon_settings_gear'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
        }
        .width(36)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(10)
        .backgroundColor(PRIMARY_BLUE)
        .opacity(0.12)

        Blank()

        Row({ space: 8 }) {
          Column() {
            Image($r('app.media.ime_icon_feature_mic'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
              .opacity(0.45)
          }
          .width(34)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          Column()
            .width(1)
            .height(24)
            .backgroundColor('#C5C8CF')

          Column() {
            Image($r('app.media.ime_icon_feature_chevron_down'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
              .opacity(0.45)
          }
          .width(34)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: 6, right: 6 })
      .alignItems(VerticalAlign.Center)

      Row({ space: 2 }) {
        ForEach(['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'], (key: string) => {
          Text(key)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
            .layoutWeight(1)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(5)
            .backgroundColor('#FFFFFF')
        })
      }
      .width('100%')

      Row({ space: 2 }) {
        Column().layoutWeight(0.5)
        ForEach(['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'], (key: string) => {
          Text(key)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
            .layoutWeight(1)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(5)
            .backgroundColor('#FFFFFF')
        })
        Column().layoutWeight(0.5)
      }
      .width('100%')

      Row({ space: 2 }) {
        Text('⇧')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
          .layoutWeight(1.5)
          .height(26)
          .textAlign(TextAlign.Center)
          .borderRadius(5)
          .backgroundColor('#C9CAD3')
        ForEach(['Z', 'X', 'C', 'V', 'B', 'N', 'M'], (key: string) => {
          Text(key)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
            .layoutWeight(1)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(5)
            .backgroundColor('#FFFFFF')
        })
        Text('⌫')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
          .layoutWeight(1.5)
          .height(26)
          .textAlign(TextAlign.Center)
          .borderRadius(5)
          .backgroundColor('#C9CAD3')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 8, left: 8, right: 8 })
    .backgroundColor('#D9DCE2')
    .borderRadius(10)
  }

  @Builder
  private renderPermissionSection() {
    Column({ space: 16 }) {
      Text('麦克风')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ top: 20 })

      Row({ space: 8 }) {
        this.renderStatusPill()

        this.renderRefreshButton()

        if (this.shouldShowMicrophonePermissionButton()) {
          Blank()
          this.renderActionButton('授权', (): void => {
            void this.requestMicrophonePermission();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 20 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderStatusPill() {
    Row({ space: 6 }) {
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.resolvePermissionColor())

      Text(this.resolvePermissionLabel())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.resolvePermissionColor())
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#F7FAFD')
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderActionButton(label: string, action: () => void) {
    Button(label)
      .height(36)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .backgroundColor(PRIMARY_BLUE)
      .borderRadius(14)
      .padding({ left: 14, right: 14 })
      .onClick((): void => {
        action();
      })
  }

  @Builder
  private renderRefreshButton() {
    Button() {
      Text('↻')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SECONDARY)
    }
    .width(32)
    .height(32)
    .backgroundColor('#F7FAFD')
    .borderRadius(16)
    .onClick((): void => {
      void this.refreshMicrophonePermissionStatus();
    })
  }

  private resolvePermissionLabel(): string {
    if (this.microphonePermissionGranted) {
      return '已授权';
    }
    if (this.microphonePermissionStatus === '请求中' || this.microphonePermissionStatus === '检查中') {
      return '检查中';
    }
    if (this.microphonePermissionStatus === '请求失败') {
      return '请求失败';
    }
    return '未授权';
  }

  private resolvePermissionColor(): string {
    if (this.microphonePermissionGranted) {
      return SUCCESS_GREEN;
    }
    if (this.microphonePermissionStatus === '请求中' || this.microphonePermissionStatus === '检查中') {
      return TEXT_SECONDARY;
    }
    return ERROR_ORANGE;
  }

  private shouldShowMicrophonePermissionButton(): boolean {
    if (this.microphonePermissionGranted) {
      return false;
    }
    return this.microphonePermissionStatus === '未授权' || this.microphonePermissionStatus === '请求失败';
  }

  private async requestMicrophonePermission(): Promise<void> {
    let hostContext = this.resolveHostContext();
    if (!hostContext) {
      this.setPermissionState(false, '不可用');
      return;
    }
    this.microphonePermissionStatus = '请求中';
    try {
      let result = await this.atManager.requestPermissionsFromUser(hostContext, [MICROPHONE_PERMISSION]);
      let requestGranted = this.hasGrantedAuthResult(result.authResults);
      let dialogShown = this.wasPermissionDialogShown(result.dialogShownResults);
      // 用户此前已选"禁止并不再询问"时，requestPermissionsFromUser 不再弹窗，
      // 需要改用 requestPermissionOnSetting 跳转到系统设置中开启
      if (!requestGranted && !dialogShown) {
        try {
          let settingStatus = await this.atManager.requestPermissionOnSetting(
            hostContext, [MICROPHONE_PERMISSION]);
          requestGranted = settingStatus.some((value: abilityAccessCtrl.GrantStatus): boolean => {
            return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
          });
        } catch (error) {
          hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
            'requestPermissionOnSetting failed: %{public}s', JSON.stringify(error));
        }
      }
      this.setPermissionState(requestGranted, requestGranted ? '已授权' : '未授权');
      let syncedGranted = await this.waitForMicrophonePermissionStatus(requestGranted);
      this.setPermissionState(syncedGranted, syncedGranted ? '已授权' : '未授权');
    } catch (_) {
      this.setPermissionState(false, '请求失败');
    }
  }

  private wasPermissionDialogShown(dialogShownResults?: Array<boolean>): boolean {
    if (!dialogShownResults) {
      return false;
    }
    return dialogShownResults.some((value: boolean): boolean => {
      return value === true;
    });
  }

  private async refreshMicrophonePermissionStatus(_context?: common.Context): Promise<void> {
    try {
      let tokenId = await this.resolveAccessTokenId();
      if (tokenId <= 0) {
        this.setPermissionState(false, '不可用');
        return;
      }
      let granted = this.queryMicrophoneGrantedSync(tokenId);
      hilog.info(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'refresh tokenId=%{public}d granted=%{public}s', tokenId, granted ? 'true' : 'false');
      this.setPermissionState(granted, granted ? '已授权' : '未授权');
    } catch (error) {
      hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'refresh failed: %{public}s', JSON.stringify(error));
      this.setPermissionState(false, '未授权');
    }
  }

  private hasGrantedAuthResult(authResults: Array<number>): boolean {
    return authResults.some((value: number): boolean => {
      return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    });
  }

  private async waitForMicrophonePermissionStatus(fallbackGranted: boolean): Promise<boolean> {
    let tokenId = await this.resolveAccessTokenId();
    if (tokenId <= 0) {
      return fallbackGranted;
    }
    for (let retryIndex = 0; retryIndex < PERMISSION_SYNC_RETRY_COUNT; retryIndex++) {
      if (this.queryMicrophoneGrantedSync(tokenId)) {
        return true;
      }
      await this.delay(PERMISSION_SYNC_RETRY_DELAY_MS);
    }
    return fallbackGranted;
  }

  private queryMicrophoneGrantedSync(tokenId: number): boolean {
    try {
      return this.atManager.checkAccessTokenSync(tokenId, MICROPHONE_PERMISSION) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'checkAccessTokenSync failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  private async resolveAccessTokenId(): Promise<number> {
    if (this.cachedTokenId > 0) {
      return this.cachedTokenId;
    }
    // 先走同进程 context 快路径，避免某些设备上 bundleManager.getBundleInfoForSelf 迟迟不返回
    let hostContext = this.resolveHostContext();
    if (hostContext) {
      try {
        let tokenId = hostContext.applicationInfo.accessTokenId;
        if (tokenId > 0) {
          this.cachedTokenId = tokenId;
          return tokenId;
        }
      } catch (error) {
        hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
          'context.applicationInfo failed: %{public}s', JSON.stringify(error));
      }
    }
    try {
      let bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      let tokenId = bundleInfo.appInfo.accessTokenId;
      if (tokenId > 0) {
        this.cachedTokenId = tokenId;
        return tokenId;
      }
    } catch (error) {
      hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'getBundleInfoForSelf failed: %{public}s', JSON.stringify(error));
    }
    return 0;
  }

  private async registerPermissionStateListener(): Promise<void> {
    if (this.permissionListenerRegistered) {
      return;
    }
    try {
      this.atManager.on('selfPermissionStateChange', [MICROPHONE_PERMISSION],
        (data: abilityAccessCtrl.PermissionStateChangeInfo): void => {
          let granted = data.change === abilityAccessCtrl.PermissionStateChangeType.PERMISSION_GRANTED_OPER;
          hilog.info(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
            'selfPermissionStateChange permission=%{public}s granted=%{public}s',
            data.permissionName, granted ? 'true' : 'false');
          this.setPermissionState(granted, granted ? '已授权' : '未授权');
        });
      this.permissionListenerRegistered = true;
    } catch (error) {
      hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'register selfPermissionStateChange failed: %{public}s', JSON.stringify(error));
    }
  }

  private unregisterPermissionStateListener(): void {
    if (!this.permissionListenerRegistered) {
      return;
    }
    try {
      this.atManager.off('selfPermissionStateChange', [MICROPHONE_PERMISSION]);
    } catch (_) {
    }
    this.permissionListenerRegistered = false;
  }

  private setPermissionState(granted: boolean, status: string): void {
    this.microphonePermissionGranted = granted;
    this.microphonePermissionStatus = status;
  }

  private async delay(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve): void => {
      setTimeout(resolve, milliseconds);
    });
  }

  private resolveHostContext(): common.UIAbilityContext | undefined {
    if (this.abilityContext) {
      return this.abilityContext;
    }
    this.abilityContext = getEntryAbilityContext();
    return this.abilityContext;
  }
}
