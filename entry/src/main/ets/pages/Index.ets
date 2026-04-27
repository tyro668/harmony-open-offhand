import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';

const PAGE_BACKGROUND = '#FFFFFF';
const PRIMARY_BLUE = '#1976F3';
const SUCCESS_GREEN = '#19A79C';
const ERROR_ORANGE = '#C46B29';
const TEXT_PRIMARY = '#121826';
const TEXT_SECONDARY = '#667085';
const DIVIDER_COLOR = '#F0F2F5';

@Entry
@Component
struct Index {
  @State private microphonePermissionStatus: string = '检查中';
  @State private microphonePermissionGranted: boolean = false;
  private readonly atManager = abilityAccessCtrl.createAtManager();

  aboutToAppear(): void {
    void this.refreshMicrophonePermissionStatus();
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

      Row({ space: 12 }) {
        this.renderStatusPill(this.resolvePermissionLabel(), this.resolvePermissionColor())

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
  private renderStatusPill(label: string, color: string) {
    Row({ space: 6 }) {
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(color)

      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
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
    let hostContext = this.resolveHostContext() as common.UIAbilityContext | undefined;
    if (!hostContext) {
      this.microphonePermissionGranted = false;
      this.microphonePermissionStatus = '不可用';
      return;
    }
    this.microphonePermissionStatus = '请求中';
    try {
      let result = await this.atManager.requestPermissionsFromUser(hostContext, [MICROPHONE_PERMISSION]);
      let granted = result.authResults.some((value: number): boolean => {
        return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      });
      this.microphonePermissionGranted = granted;
      this.microphonePermissionStatus = granted ? '已授权' : '未授权';
    } catch (_) {
      this.microphonePermissionGranted = false;
      this.microphonePermissionStatus = '请求失败';
    }
    await this.refreshMicrophonePermissionStatus(hostContext);
  }

  private async refreshMicrophonePermissionStatus(context?: common.Context): Promise<void> {
    let hostContext = (context ?? this.resolveHostContext()) as common.UIAbilityContext | undefined;
    if (!hostContext) {
      this.microphonePermissionGranted = false;
      this.microphonePermissionStatus = '不可用';
      return;
    }
    try {
      let grantStatus = this.atManager.checkAccessTokenSync(
        hostContext.applicationInfo.accessTokenId,
        MICROPHONE_PERMISSION
      );
      this.microphonePermissionGranted = grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      this.microphonePermissionStatus = this.microphonePermissionGranted ? '已授权' : '未授权';
    } catch (_) {
      this.microphonePermissionGranted = false;
      this.microphonePermissionStatus = '未授权';
    }
  }

  private resolveHostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext() as common.Context | undefined;
  }
}
