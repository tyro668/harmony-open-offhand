import { Want } from '@kit.AbilityKit';
import { InputMethodExtensionAbility, InputMethodSubtype, inputMethodEngine } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import display from '@ohos.display';
import { ConfigRepository } from '../config/ConfigRepository';
import { RimeService } from '../engine/rime/RimeService';
import { imeRuntime } from '../runtime/ImeRuntime';
import { SessionManager } from '../session/SessionManager';

const DOMAIN = 0xFF10;
const TAG = 'OffhandIME';

class KeyboardPanelSize {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

export default class OffhandInputMethodExtensionAbility extends InputMethodExtensionAbility {
  private inputMethodAbility?: inputMethodEngine.InputMethodAbility;
  private readonly configRepository = new ConfigRepository();
  private readonly rimeService = new RimeService();
  private readonly sessionManager = new SessionManager(this.configRepository, this.rimeService);
  private keyboardPanel?: inputMethodEngine.Panel;
  private bootstrapPromise?: Promise<void>;

  private readonly onInputStart = (keyboardController: inputMethodEngine.KeyboardController,
    inputClient: inputMethodEngine.InputClient): void => {
    hilog.info(DOMAIN, TAG, 'inputStart received');
    void this.runTask('inputStart', async (): Promise<void> => {
      await this.awaitBootstrap();
      await this.sessionManager.handleInputStart(keyboardController, inputClient);
    });
  };

  private readonly onInputStop = (): void => {
    hilog.info(DOMAIN, TAG, 'inputStop received');
    void this.runTask('inputStop', async (): Promise<void> => {
      await this.sessionManager.handleInputStop();
    });
  };

  private readonly onKeyboardShow = (): void => {
    hilog.info(DOMAIN, TAG, 'keyboardShow received');
    void this.runTask('keyboardShow', async (): Promise<void> => {
      await this.awaitBootstrap();
      await this.sessionManager.handleKeyboardShow();
    });
  };

  private readonly onKeyboardHide = (): void => {
    hilog.info(DOMAIN, TAG, 'keyboardHide received');
    void this.runTask('keyboardHide', async (): Promise<void> => {
      await this.sessionManager.handleKeyboardHide();
    });
  };

  private readonly onSubtypeChange = (subtype: InputMethodSubtype): void => {
    void this.runTask('setSubtype', async (): Promise<void> => {
      await this.awaitBootstrap();
      await this.sessionManager.handleSubtypeChange(subtype);
    });
  };

  private readonly onSecurityModeChange = (mode: number): void => {
    void this.runTask('securityModeChange', async (): Promise<void> => {
      await this.awaitBootstrap();
      await this.sessionManager.handleSecurityModeChange(mode);
    });
  };

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'Input method extension created: %{public}s', JSON.stringify(want));
    this.inputMethodAbility = inputMethodEngine.getInputMethodAbility();
    imeRuntime.setSessionManager(this.sessionManager);
    this.bootstrapPromise = this.bootstrap();
  }

  onDestroy(): void {
    this.unregisterEvents();
    this.sessionManager.dispose();
    hilog.info(DOMAIN, TAG, 'Input method extension destroyed');
  }

  private async bootstrap(): Promise<void> {
    await this.sessionManager.initialize(this.context);
    await this.ensureKeyboardPanel();
    this.registerEvents();
    try {
      await this.sessionManager.handleSecurityModeChange(this.requireInputMethodAbility().getSecurityMode());
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to query initial security mode: %{public}s', JSON.stringify(error));
    }
  }

  private async ensureKeyboardPanel(): Promise<void> {
    if (this.keyboardPanel) {
      return;
    }
    try {
      let inputMethodAbility = this.requireInputMethodAbility();
      let panelInfo: inputMethodEngine.PanelInfo = {
        type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
        flag: inputMethodEngine.PanelFlag.FLG_FIXED
      };
      let keyboardPanel = await inputMethodAbility.createPanel(this.context, panelInfo);
      await keyboardPanel.setUiContent('ime/panel/KeyboardPanel');
      let panelSize = this.resolveKeyboardPanelSize();
      await keyboardPanel.resize(panelSize.width, panelSize.height);
      this.keyboardPanel = keyboardPanel;
      this.sessionManager.bindPanel(keyboardPanel);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to create keyboard panel: %{public}s', JSON.stringify(error));
    }
  }

  private resolveKeyboardPanelSize(): KeyboardPanelSize {
    try {
      let currentDisplay = display.getDefaultDisplaySync();
      let width = Math.max(720, currentDisplay.width);
      let estimatedHeight = Math.round(currentDisplay.height * 0.34);
      let height = Math.max(640, Math.min(estimatedHeight, 980));
      return new KeyboardPanelSize(width, height);
    } catch (_) {
      return new KeyboardPanelSize(1320, 860);
    }
  }

  private registerEvents(): void {
    let inputMethodAbility = this.requireInputMethodAbility();
    hilog.info(DOMAIN, TAG, 'Registering input method events');
    inputMethodAbility.on('inputStart', this.onInputStart);
    inputMethodAbility.on('inputStop', this.onInputStop);
    inputMethodAbility.on('keyboardShow', this.onKeyboardShow);
    inputMethodAbility.on('keyboardHide', this.onKeyboardHide);
    inputMethodAbility.on('setSubtype', this.onSubtypeChange);
    inputMethodAbility.on('securityModeChange', this.onSecurityModeChange);
  }

  private unregisterEvents(): void {
    if (!this.inputMethodAbility) {
      return;
    }
    this.inputMethodAbility.off('inputStart', this.onInputStart);
    this.inputMethodAbility.off('inputStop', this.onInputStop);
    this.inputMethodAbility.off('keyboardShow', this.onKeyboardShow);
    this.inputMethodAbility.off('keyboardHide', this.onKeyboardHide);
    this.inputMethodAbility.off('setSubtype', this.onSubtypeChange);
    this.inputMethodAbility.off('securityModeChange', this.onSecurityModeChange);
  }

  private async awaitBootstrap(): Promise<void> {
    if (!this.bootstrapPromise) {
      return;
    }
    await this.bootstrapPromise;
  }

  private async runTask(name: string, task: () => Promise<void>): Promise<void> {
    try {
      await task();
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', name, JSON.stringify(error));
    }
  }

  private requireInputMethodAbility(): inputMethodEngine.InputMethodAbility {
    if (!this.inputMethodAbility) {
      this.inputMethodAbility = inputMethodEngine.getInputMethodAbility();
    }
    return this.inputMethodAbility;
  }
}
