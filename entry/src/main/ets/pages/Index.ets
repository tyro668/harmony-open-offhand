import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';

const MICROPHONE_PERMISSION: 'ohos.permission.MICROPHONE' = 'ohos.permission.MICROPHONE';

const PAGE_BACKGROUND = '#F4F7FB';
const CARD_BACKGROUND = '#FFFFFF';
const CARD_BORDER = '#E7EDF5';
const CARD_SHADOW: ShadowOptions = {
  radius: 10,
  color: '#140A2540',
  offsetX: 0,
  offsetY: 6
};
const PRIMARY_BLUE = '#1976F3';
const SUCCESS_GREEN = '#19A79C';
const ERROR_ORANGE = '#C46B29';
const TEXT_PRIMARY = '#121826';
const TEXT_SECONDARY = '#667085';

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
    Scroll() {
      Column({ space: 12 }) {
        this.renderEntryCard()
        this.renderPermissionCard()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
  }

  @Builder
  private renderEntryCard() {
    Column({ space: 12 }) {
      Text('输入法内配置')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('在键盘左上角打开配置。')
        .fontSize(14)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      this.renderStatusPill('键盘内配置', PRIMARY_BLUE)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(CARD_BACKGROUND)
    .borderRadius(24)
    .border({ width: 1, color: CARD_BORDER })
    .shadow(CARD_SHADOW)
  }

  @Builder
  private renderPermissionCard() {
    Column({ space: 14 }) {
      Text('麦克风')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)

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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(CARD_BACKGROUND)
    .borderRadius(24)
    .border({ width: 1, color: CARD_BORDER })
    .shadow(CARD_SHADOW)
  }

  @Builder
  private renderStatusPill(label: string, color: string) {
    Row({ space: 8 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(color)

      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
    }
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#F7FAFD')
    .borderRadius(18)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private renderActionButton(label: string, action: () => void) {
    Button(label)
      .height(40)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .backgroundColor(PRIMARY_BLUE)
      .borderRadius(16)
      .padding({ left: 16, right: 16 })
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
