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

interface PanelWithAdjustRect {
  adjustPanelRect?: (flag: inputMethodEngine.PanelFlag, rect: inputMethodEngine.PanelRect) => Promise<void>;
}

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
  private displayChangeRegistered: boolean = false;

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
    this.unregisterDisplayChangeListener();
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
      // SOFT_KEYBOARD + FLG_FIXED: the system docks this panel to the bottom of the
      // focused window and automatically raises the focused editor above the
      // keyboard area, keeping the input cursor visible in sync with the keyboard.
      let panelInfo: inputMethodEngine.PanelInfo = {
        type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
        flag: inputMethodEngine.PanelFlag.FLG_FIXED
      };
      let keyboardPanel = await inputMethodAbility.createPanel(this.context, panelInfo);
      await keyboardPanel.setUiContent('ime/panel/KeyboardPanel');
      await this.applyKeyboardPanelSize(keyboardPanel);
      this.keyboardPanel = keyboardPanel;
      this.sessionManager.bindPanel(keyboardPanel);
      this.registerDisplayChangeListener();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to create keyboard panel: %{public}s', JSON.stringify(error));
    }
  }

  private async applyKeyboardPanelSize(panel: inputMethodEngine.Panel): Promise<void> {
    let portrait = this.resolveKeyboardPanelSize(false);
    let landscape = this.resolveKeyboardPanelSize(true);
    // Prefer adjustPanelRect: it reports both portrait and landscape rects to
    // the window manager so it can compute the keyboard avoid area and lift
    // the focused editor above the keyboard on every orientation. Fall back to
    // resize() for older API levels that only implement the legacy path.
    let adjusted = false;
    try {
      let panelWithAdjust = panel as ESObject as PanelWithAdjustRect;
      if (typeof panelWithAdjust.adjustPanelRect === 'function') {
        let rect: inputMethodEngine.PanelRect = {
          landscapeRect: { left: 0, top: 0, width: landscape.width, height: landscape.height },
          portraitRect: { left: 0, top: 0, width: portrait.width, height: portrait.height }
        };
        await panelWithAdjust.adjustPanelRect(inputMethodEngine.PanelFlag.FLG_FIXED, rect);
        adjusted = true;
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'adjustPanelRect failed, falling back to resize: %{public}s',
        JSON.stringify(error));
    }
    if (!adjusted) {
      let fallback = this.resolveKeyboardPanelSize(false);
      try {
        await panel.resize(fallback.width, fallback.height);
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'Failed to resize keyboard panel: %{public}s', JSON.stringify(error));
      }
    }
  }

  private resolveKeyboardPanelSize(landscape: boolean): KeyboardPanelSize {
    try {
      let currentDisplay = display.getDefaultDisplaySync();
      let displayWidth = currentDisplay.width;
      let displayHeight = currentDisplay.height;
      let shortSide = Math.min(displayWidth, displayHeight);
      let longSide = Math.max(displayWidth, displayHeight);
      // FLG_FIXED soft keyboard width must equal the screen width on the
      // matching orientation so the avoid area calculation covers the full
      // bottom strip; otherwise the focused editor is not lifted properly.
      let width = landscape ? longSide : shortSide;
      let baseHeight = landscape ? shortSide : longSide;
      // Portrait keyboards occupy ~38% of the long side, landscape keyboards
      // ~48% of the short side, mirroring standard mobile IME proportions so
      // the editor cursor stays comfortably above the keyboard.
      let ratio = landscape ? 0.48 : 0.38;
      let estimatedHeight = Math.round(baseHeight * ratio);
      let minHeight = Math.round(shortSide * 0.32);
      let maxHeight = Math.round(longSide * 0.5);
      let height = Math.max(minHeight, Math.min(estimatedHeight, maxHeight));
      return new KeyboardPanelSize(width, height);
    } catch (_) {
      return landscape ? new KeyboardPanelSize(1920, 520) : new KeyboardPanelSize(1080, 820);
    }
  }

  private registerDisplayChangeListener(): void {
    if (this.displayChangeRegistered) {
      return;
    }
    try {
      display.on('change', this.onDisplayChange);
      this.displayChangeRegistered = true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to register display change listener: %{public}s', JSON.stringify(error));
    }
  }

  private unregisterDisplayChangeListener(): void {
    if (!this.displayChangeRegistered) {
      return;
    }
    try {
      display.off('change', this.onDisplayChange);
    } catch (_) {
    }
    this.displayChangeRegistered = false;
  }

  private readonly onDisplayChange = (_: number): void => {
    if (!this.keyboardPanel) {
      return;
    }
    void this.runTask('displayChange', async (): Promise<void> => {
      if (this.keyboardPanel) {
        await this.applyKeyboardPanelSize(this.keyboardPanel);
      }
    });
  };

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
