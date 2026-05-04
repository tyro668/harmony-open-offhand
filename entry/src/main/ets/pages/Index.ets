import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { bundleManager, common, Want } from '@kit.AbilityKit';
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
const ILLUSTRATION_KEY_GAP = 4;
const ILLUSTRATION_ROW_GAP = 6;
const ILLUSTRATION_KEY_HEIGHT = 38;
const ILLUSTRATION_TOOLBAR_HEIGHT = 40;
const ILLUSTRATION_KEY_RADIUS = 8;

interface IllustrationKeyDescriptor {
  label: string;
  hint: string;
  weight: number;
  gray: boolean;
}

const ILLUSTRATION_TOP_KEYS: IllustrationKeyDescriptor[] = [
  { label: 'Q', hint: '1', weight: 1, gray: false },
  { label: 'W', hint: '2', weight: 1, gray: false },
  { label: 'E', hint: '3', weight: 1, gray: false },
  { label: 'R', hint: '4', weight: 1, gray: false },
  { label: 'T', hint: '5', weight: 1, gray: false },
  { label: 'Y', hint: '6', weight: 1, gray: false },
  { label: 'U', hint: '7', weight: 1, gray: false },
  { label: 'I', hint: '8', weight: 1, gray: false },
  { label: 'O', hint: '9', weight: 1, gray: false },
  { label: 'P', hint: '0', weight: 1, gray: false }
];

const ILLUSTRATION_MIDDLE_KEYS: IllustrationKeyDescriptor[] = [
  { label: 'A', hint: '~', weight: 1, gray: false },
  { label: 'S', hint: '@', weight: 1, gray: false },
  { label: 'D', hint: '#', weight: 1, gray: false },
  { label: 'F', hint: '$', weight: 1, gray: false },
  { label: 'G', hint: '%', weight: 1, gray: false },
  { label: 'H', hint: '&', weight: 1, gray: false },
  { label: 'J', hint: '*', weight: 1, gray: false },
  { label: 'K', hint: '(', weight: 1, gray: false },
  { label: 'L', hint: ')', weight: 1, gray: false }
];

const ILLUSTRATION_BOTTOM_KEYS: IllustrationKeyDescriptor[] = [
  { label: 'Z', hint: '\'', weight: 1, gray: false },
  { label: 'X', hint: '/', weight: 1, gray: false },
  { label: 'C', hint: '-', weight: 1, gray: false },
  { label: 'V', hint: '_', weight: 1, gray: false },
  { label: 'B', hint: ':', weight: 1, gray: false },
  { label: 'N', hint: ';', weight: 1, gray: false },
  { label: 'M', hint: '`', weight: 1, gray: false }
];

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
      this.renderEntrySection()
      this.renderDivider()
      this.renderImeSettingsSection()
      this.renderDivider()
      this.renderPermissionSection()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
    .padding({ left: 20, right: 20, top: 20 })
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
      Text($r('app.string.settings_entry_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ top: 20 })

      this.renderKeyboardIllustration()

      Text($r('app.string.settings_entry_hint'))
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
    Column({ space: ILLUSTRATION_ROW_GAP }) {
      this.renderIllustrationToolbar()
      this.renderIllustrationKeyRow(ILLUSTRATION_TOP_KEYS)
      this.renderIllustrationMiddleKeyRow()
      this.renderIllustrationBottomLetterRow()
      this.renderIllustrationBottomActionRow()
    }
    .width('100%')
    .padding({ top: 4, bottom: 7, left: 8, right: 8 })
    .backgroundColor('#D9DCE2')
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private renderIllustrationToolbar() {
    Row() {
      this.renderIllustrationToolbarIcon('gear', 34, 30, 26, 26, 1)

      Blank()

      Row({ space: 8 }) {
        this.renderIllustrationToolbarIcon('mic', 32, 30, 23, 23, 0.76)

        Column()
          .width(1)
          .height(24)
          .backgroundColor('#C5C8CF')

        this.renderIllustrationToolbarIcon('chevron', 32, 30, 24, 24, 0.78)
      }
      .height('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(ILLUSTRATION_TOOLBAR_HEIGHT)
    .padding({ left: 0, right: 0 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderIllustrationToolbarIcon(kind: string, buttonWidth: number, buttonHeight: number,
    iconWidth: number, iconHeight: number, opacity: number) {
    Column() {
      this.renderIllustrationIcon(kind, iconWidth, iconHeight, opacity)
    }
    .width(buttonWidth)
    .height(buttonHeight)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private renderIllustrationKeyRow(keys: IllustrationKeyDescriptor[]) {
    Row({ space: ILLUSTRATION_KEY_GAP }) {
      ForEach(keys, (descriptor: IllustrationKeyDescriptor) => {
        this.renderIllustrationLetterKey(descriptor)
      }, (descriptor: IllustrationKeyDescriptor): string => `${descriptor.label}-${descriptor.hint}`)
    }
    .width('100%')
  }

  @Builder
  private renderIllustrationMiddleKeyRow() {
    Row({ space: ILLUSTRATION_KEY_GAP }) {
      Column().layoutWeight(0.5)
      ForEach(ILLUSTRATION_MIDDLE_KEYS, (descriptor: IllustrationKeyDescriptor) => {
        this.renderIllustrationLetterKey(descriptor)
      }, (descriptor: IllustrationKeyDescriptor): string => `${descriptor.label}-${descriptor.hint}`)
      Column().layoutWeight(0.5)
    }
    .width('100%')
  }

  @Builder
  private renderIllustrationBottomLetterRow() {
    Row({ space: ILLUSTRATION_KEY_GAP }) {
      this.renderIllustrationIconKey('shift', 1.5)
      ForEach(ILLUSTRATION_BOTTOM_KEYS, (descriptor: IllustrationKeyDescriptor) => {
        this.renderIllustrationLetterKey(descriptor)
      }, (descriptor: IllustrationKeyDescriptor): string => `${descriptor.label}-${descriptor.hint}`)
      this.renderIllustrationIconKey('backspace', 1.5)
    }
    .width('100%')
  }

  @Builder
  private renderIllustrationBottomActionRow() {
    Row({ space: ILLUSTRATION_KEY_GAP }) {
      this.renderIllustrationActionKey('符号', 1.64)
      this.renderIllustrationActionKey('中/英', 1.2)
      this.renderIllustrationPunctuationKey('，', '!', 1)
      this.renderIllustrationSpaceKey(2.95)
      this.renderIllustrationPunctuationKey('。', '?', 1)
      this.renderIllustrationActionKey('123', 1.2)
      this.renderIllustrationActionKey('换行', 1.64)
    }
    .width('100%')
  }

  @Builder
  private renderIllustrationLetterKey(descriptor: IllustrationKeyDescriptor) {
    Column({ space: 0 }) {
      Text(descriptor.hint)
        .fontSize(8)
        .fontColor('#8F9299')
        .maxLines(1)

      Text(descriptor.label)
        .fontSize(17)
        .minFontSize(12)
        .maxFontSize(17)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Normal)
        .fontColor('#050608')
        .maxLines(1)
    }
    .layoutWeight(descriptor.weight)
    .height(ILLUSTRATION_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(descriptor.gray ? '#C2C6CE' : '#FFFFFF')
    .border({ width: 1, color: descriptor.gray ? '#B8BDC7' : '#F8F9FB' })
    .borderRadius(ILLUSTRATION_KEY_RADIUS)
    .shadow(this.resolveIllustrationKeyShadow(descriptor.gray))
  }

  @Builder
  private renderIllustrationIconKey(kind: string, weight: number) {
    Column() {
      this.renderIllustrationIcon(kind, 27, 22, 1)
    }
    .layoutWeight(weight)
    .height(ILLUSTRATION_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#C2C6CE')
    .border({ width: 1, color: '#B8BDC7' })
    .borderRadius(ILLUSTRATION_KEY_RADIUS)
    .shadow(this.resolveIllustrationKeyShadow(true))
  }

  @Builder
  private renderIllustrationActionKey(label: string, weight: number) {
    Column() {
      Text(label)
        .fontSize(label === '中/英' ? 13 : 15)
        .minFontSize(10)
        .maxFontSize(label === '中/英' ? 13 : 15)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor('#08090C')
        .maxLines(1)
    }
    .layoutWeight(weight)
    .height(ILLUSTRATION_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#C2C6CE')
    .border({ width: 1, color: '#B8BDC7' })
    .borderRadius(ILLUSTRATION_KEY_RADIUS)
    .shadow(this.resolveIllustrationKeyShadow(true))
  }

  @Builder
  private renderIllustrationPunctuationKey(label: string, hint: string, weight: number) {
    Column({ space: 0 }) {
      Text(hint)
        .fontSize(8)
        .fontColor('#8F9299')
        .textAlign(TextAlign.Center)
        .maxLines(1)

      Text(label)
        .fontSize(17)
        .minFontSize(12)
        .maxFontSize(17)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
        .fontWeight(FontWeight.Medium)
        .fontColor('#050608')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .layoutWeight(weight)
    .height(ILLUSTRATION_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(ILLUSTRATION_KEY_RADIUS)
    .shadow(this.resolveIllustrationKeyShadow(false))
  }

  @Builder
  private renderIllustrationSpaceKey(weight: number) {
    Column({ space: 4 }) {
      this.renderIllustrationIcon('mic', 20, 18, 0.76)

      Row() {
        Column()
          .width(3)
          .height(8)
          .backgroundColor('#111214')

        Column()
          .width(38)
          .height(3)
          .backgroundColor('#111214')

        Column()
          .width(3)
          .height(8)
          .backgroundColor('#111214')
      }
      .height(10)
      .alignItems(VerticalAlign.Bottom)
    }
    .layoutWeight(weight)
    .height(ILLUSTRATION_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F8F9FB' })
    .borderRadius(ILLUSTRATION_KEY_RADIUS)
    .shadow(this.resolveIllustrationKeyShadow(false))
  }

  @Builder
  private renderIllustrationIcon(kind: string, width: number, height: number, opacity: number) {
    if (kind === 'gear') {
      Image($r('app.media.ime_icon_settings_gear'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'mic') {
      Image($r('app.media.ime_icon_feature_mic'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'chevron') {
      Image($r('app.media.ime_icon_feature_chevron_down'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else if (kind === 'shift') {
      Image($r('app.media.ime_icon_key_shift'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    } else {
      Image($r('app.media.ime_icon_key_backspace'))
        .width(width)
        .height(height)
        .objectFit(ImageFit.Contain)
        .opacity(opacity)
    }
  }

  private resolveIllustrationKeyShadow(gray: boolean): ShadowOptions {
    return {
      radius: 1.3,
      color: gray ? '#2C000000' : '#36000000',
      offsetX: 0,
      offsetY: 2
    };
  }

  @Builder
  private renderImeSettingsSection() {
    Column({ space: 16 }) {
      Text($r('app.string.settings_enable_ime_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ top: 20 })

      Row({ space: 12 }) {
        Text($r('app.string.settings_enable_ime_hint'))
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)

        Button($r('app.string.settings_go_to_settings'))
          .height(36)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(PRIMARY_BLUE)
          .backgroundColor('#EBF0FF')
          .borderRadius(14)
          .padding({ left: 14, right: 14 })
          .onClick((): void => {
            void this.openImeSystemSettings();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 20 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private async openImeSystemSettings(): Promise<void> {
    let context = this.resolveHostContext();
    if (!context) {
      return;
    }
    // 不同 HarmonyOS 版本的设置子页 URI 不一致，传入未知 URI 会落到空白页。
    // 这里直接打开“设置”首页，由用户手动进入 系统 → 输入法 → 管理输入法 启用本输入法。
    let want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility'
    };
    try {
      await context.startAbility(want);
    } catch (error) {
      hilog.warn(PERMISSION_LOG_DOMAIN, PERMISSION_LOG_TAG,
        'open settings home failed: %{public}s', JSON.stringify(error));
    }
  }

  @Builder
  private renderPermissionSection() {
    Column({ space: 16 }) {
      Text($r('app.string.settings_microphone_title'))
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
          this.renderActionButton($r('app.string.settings_authorize'), (): void => {
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
  private renderActionButton(label: ResourceStr, action: () => void) {
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

  private resolvePermissionLabel(): ResourceStr {
    if (this.microphonePermissionGranted) {
      return $r('app.string.permission_granted');
    }
    if (this.microphonePermissionStatus === '请求中' || this.microphonePermissionStatus === '检查中') {
      return $r('app.string.permission_checking');
    }
    if (this.microphonePermissionStatus === '请求失败') {
      return $r('app.string.permission_request_failed');
    }
    return $r('app.string.permission_not_granted');
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
