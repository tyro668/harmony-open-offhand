import { Want } from '@kit.AbilityKit';
import { InputMethodExtensionAbility, InputMethodSubtype, inputMethodEngine } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import commonEventManager from '@ohos.commonEventManager';
import display from '@ohos.display';
import { ConfigRepository } from '../config/ConfigRepository';
import { RimeService } from '../engine/rime/RimeService';
import { imeRuntime } from '../runtime/ImeRuntime';
import { SessionManager } from '../session/SessionManager';

const DOMAIN = 0xFF10;
const TAG = 'OffhandIME';
const KEYBOARD_PANEL_CONTENT_HEIGHT: number = 270;
const KEYBOARD_PANEL_VERTICAL_PADDING: number = 16;
const KEYBOARD_PANEL_MIN_HEIGHT: number = KEYBOARD_PANEL_CONTENT_HEIGHT + KEYBOARD_PANEL_VERTICAL_PADDING;
const KEYBOARD_PANEL_REFERENCE_WIDTH: number = 1080;
const KEYBOARD_PANEL_REFERENCE_HEIGHT: number = 816;

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
  private keyboardPanelPromise?: Promise<void>;
  private bootstrapPromise?: Promise<void>;
  private displayChangeRegistered: boolean = false;
  private eventsRegistered: boolean = false;
  private screenEventSubscriber?: commonEventManager.CommonEventSubscriber;
  private screenEventRegistered: boolean = false;

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
      await this.ensureKeyboardPanel();
      await this.awaitBootstrap();
      await this.ensureKeyboardPanel();
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
    this.registerEvents();
    void this.registerScreenEventListener();
    this.bootstrapPromise = this.bootstrap();
  }

  onDestroy(): void {
    this.unregisterEvents();
    this.unregisterDisplayChangeListener();
    this.unregisterScreenEventListener();
    this.sessionManager.dispose();
    hilog.info(DOMAIN, TAG, 'Input method extension destroyed');
  }

  private async bootstrap(): Promise<void> {
    await this.ensureKeyboardPanel();
    try {
      await this.sessionManager.initialize(this.context);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to initialize IME session: %{public}s', JSON.stringify(error));
    }
    await this.ensureKeyboardPanel();
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
    if (this.keyboardPanelPromise) {
      await this.keyboardPanelPromise;
      return;
    }
    this.keyboardPanelPromise = this.createKeyboardPanel();
    try {
      await this.keyboardPanelPromise;
    } finally {
      this.keyboardPanelPromise = undefined;
    }
  }

  private async createKeyboardPanel(): Promise<void> {
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
      this.keyboardPanel = undefined;
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
      // The portrait keyboard artwork is designed from the 1080x816 reference
      // screenshots, so portrait height scales from the screen width. Landscape
      // keeps the shorter-side ratio to avoid occupying too much vertical room.
      let estimatedHeight = landscape ? Math.round(shortSide * 0.40) :
        Math.round(shortSide * KEYBOARD_PANEL_REFERENCE_HEIGHT / KEYBOARD_PANEL_REFERENCE_WIDTH);
      let minHeight = Math.max(KEYBOARD_PANEL_MIN_HEIGHT, Math.round(shortSide * 0.26));
      let maxHeight = Math.round(longSide * 0.42);
      let height = Math.max(minHeight, Math.min(estimatedHeight, Math.max(minHeight, maxHeight)));
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
    void this.runTask('displayChange', async (): Promise<void> => {
      if (this.isDefaultDisplayOff()) {
        await this.sessionManager.handleExternalVoiceCancel('displayOff');
        return;
      }
      if (this.keyboardPanel) {
        await this.applyKeyboardPanelSize(this.keyboardPanel);
      }
    });
  };

  private async registerScreenEventListener(): Promise<void> {
    if (this.screenEventRegistered || this.screenEventSubscriber) {
      return;
    }
    try {
      let subscriber = await commonEventManager.createSubscriber({
        events: [commonEventManager.Support.COMMON_EVENT_SCREEN_OFF]
      });
      commonEventManager.subscribe(subscriber, (error, data): void => {
        if (error) {
          hilog.warn(DOMAIN, TAG, 'screen event callback error: %{public}s', JSON.stringify(error));
          return;
        }
        if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_OFF) {
          void this.runTask('screenOff', async (): Promise<void> => {
            await this.sessionManager.handleExternalVoiceCancel('screenOff');
          });
        }
      });
      this.screenEventSubscriber = subscriber;
      this.screenEventRegistered = true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Failed to register screen event listener: %{public}s', JSON.stringify(error));
    }
  }

  private unregisterScreenEventListener(): void {
    if (!this.screenEventSubscriber || !this.screenEventRegistered) {
      return;
    }
    try {
      commonEventManager.unsubscribe(this.screenEventSubscriber);
    } catch (_) {
    }
    this.screenEventSubscriber = undefined;
    this.screenEventRegistered = false;
  }

  private isDefaultDisplayOff(): boolean {
    try {
      return display.getDefaultDisplaySync().state === display.DisplayState.STATE_OFF;
    } catch (_) {
      return false;
    }
  }

  private registerEvents(): void {
    if (this.eventsRegistered) {
      return;
    }
    let inputMethodAbility = this.requireInputMethodAbility();
    hilog.info(DOMAIN, TAG, 'Registering input method events');
    inputMethodAbility.on('inputStart', this.onInputStart);
    inputMethodAbility.on('inputStop', this.onInputStop);
    inputMethodAbility.on('keyboardShow', this.onKeyboardShow);
    inputMethodAbility.on('keyboardHide', this.onKeyboardHide);
    inputMethodAbility.on('setSubtype', this.onSubtypeChange);
    inputMethodAbility.on('securityModeChange', this.onSecurityModeChange);
    this.eventsRegistered = true;
  }

  private unregisterEvents(): void {
    if (!this.inputMethodAbility || !this.eventsRegistered) {
      return;
    }
    this.inputMethodAbility.off('inputStart', this.onInputStart);
    this.inputMethodAbility.off('inputStop', this.onInputStop);
    this.inputMethodAbility.off('keyboardShow', this.onKeyboardShow);
    this.inputMethodAbility.off('keyboardHide', this.onKeyboardHide);
    this.inputMethodAbility.off('setSubtype', this.onSubtypeChange);
    this.inputMethodAbility.off('securityModeChange', this.onSecurityModeChange);
    this.eventsRegistered = false;
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
