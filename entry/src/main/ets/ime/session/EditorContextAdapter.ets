import { inputMethodEngine } from '@kit.IMEKit';
import { InputSessionContext, OffhandSubtypeConfig } from '../common/ImeTypes';

export class EditorContextAdapter {
  private readonly inputClient: inputMethodEngine.InputClient;
  private previewEnabled: boolean = false;
  private previewActive: boolean = false;
  private previewStart: number = 0;
  private previewEnd: number = 0;

  constructor(inputClient: inputMethodEngine.InputClient) {
    this.inputClient = inputClient;
  }

  setPreviewEnabled(enabled: boolean): void {
    this.previewEnabled = enabled;
  }

  async buildSessionContext(subtype: OffhandSubtypeConfig, securityMode: number): Promise<InputSessionContext> {
    try {
      let attribute = await this.inputClient.getEditorAttribute();
      return {
        inputPattern: attribute.inputPattern,
        enterKeyType: attribute.enterKeyType,
        placeholder: attribute.placeholder ?? '',
        abilityName: attribute.abilityName ?? '',
        bundleName: attribute.bundleName ?? '',
        securityMode: securityMode,
        subtypeId: subtype.id,
        schemaId: subtype.schemaId ?? '',
        keyboardLayout: subtype.keyboardLayout,
        supportsPreviewText: attribute.isTextPreviewSupported === true
      };
    } catch (_) {
      return {
        inputPattern: inputMethodEngine.PATTERN_TEXT,
        enterKeyType: inputMethodEngine.ENTER_KEY_TYPE_NEWLINE,
        placeholder: '',
        abilityName: '',
        bundleName: '',
        securityMode: securityMode,
        subtypeId: subtype.id,
        schemaId: subtype.schemaId ?? '',
        keyboardLayout: subtype.keyboardLayout,
        supportsPreviewText: false
      };
    }
  }

  async insertText(text: string): Promise<boolean> {
    try {
      return await this.inputClient.insertText(text);
    } catch (_) {
      return false;
    }
  }

  async deleteBackward(length: number): Promise<boolean> {
    try {
      // HarmonyOS InputClient naming is counterintuitive: `deleteForward`
      // deletes text BEFORE the cursor (Backspace behavior), while
      // `deleteBackward` deletes text AFTER the cursor (Delete key). Our IME
      // backspace button is expected to delete the char just typed, so it
      // must call `deleteForward`.
      return await this.inputClient.deleteForward(length);
    } catch (_) {
      return false;
    }
  }

  // Deletes the entire contents of the active editor by iteratively reading
  // the text before and after the cursor (no InputClient API exposes total
  // length directly) and issuing delete calls for each half. We loop until
  // both halves are empty or until we stop making progress so that a faulty
  // editor cannot spin us forever.
  async deleteAllText(): Promise<void> {
    const BATCH_SIZE: number = 1024;
    const MAX_ITERATIONS: number = 128;
    for (let iteration = 0; iteration < MAX_ITERATIONS; iteration++) {
      let beforeLen = 0;
      let afterLen = 0;
      try {
        let before = await this.inputClient.getForward(BATCH_SIZE);
        beforeLen = typeof before === 'string' ? before.length : 0;
      } catch (_) {
        beforeLen = 0;
      }
      try {
        let after = await this.inputClient.getBackward(BATCH_SIZE);
        afterLen = typeof after === 'string' ? after.length : 0;
      } catch (_) {
        afterLen = 0;
      }
      if (beforeLen === 0 && afterLen === 0) {
        return;
      }
      let progressed = false;
      if (beforeLen > 0) {
        try {
          let ok = await this.inputClient.deleteForward(beforeLen);
          if (ok) {
            progressed = true;
          }
        } catch (_) {
        }
      }
      if (afterLen > 0) {
        try {
          let ok = await this.inputClient.deleteBackward(afterLen);
          if (ok) {
            progressed = true;
          }
        } catch (_) {
        }
      }
      if (!progressed) {
        return;
      }
    }
  }

  async replaceRecentText(previousText: string, nextText: string): Promise<boolean> {
    if (previousText.length > 0) {
      let deleted = await this.deleteBackward(previousText.length);
      if (!deleted) {
        return false;
      }
    }
    if (nextText.length === 0) {
      return true;
    }
    return await this.insertText(nextText);
  }

  async updatePreviewText(text: string): Promise<boolean> {
    if (!this.previewEnabled) {
      return false;
    }
    if (text.length === 0) {
      await this.clearPreviewText();
      return true;
    }
    try {
      let range: inputMethodEngine.Range;
      if (this.previewActive) {
        range = {
          start: this.previewStart,
          end: this.previewEnd
        };
      } else {
        range = await this.createCollapsedRangeAtCursor();
      }
      await this.inputClient.setPreviewText(text, range);
      this.previewActive = true;
      this.previewStart = range.start;
      this.previewEnd = this.previewStart + text.length;
      return true;
    } catch (_) {
      return false;
    }
  }

  async clearPreviewText(): Promise<void> {
    if (!this.previewActive && !this.previewEnabled) {
      return;
    }
    try {
      // If preview is currently active, first overwrite it with empty text so
      // finishTextPreview() does not commit the leftover preedit (e.g. pinyin
      // letters) into the editor before the real commit text is inserted.
      if (this.previewActive) {
        let range: inputMethodEngine.Range = {
          start: this.previewStart,
          end: this.previewEnd
        };
        try {
          await this.inputClient.setPreviewText('', range);
        } catch (_) {
        }
      }
      await this.inputClient.finishTextPreview();
    } catch (_) {
    } finally {
      this.previewActive = false;
      this.previewStart = 0;
      this.previewEnd = 0;
    }
  }

  private async createCollapsedRangeAtCursor(): Promise<inputMethodEngine.Range> {
    try {
      let cursor = await this.inputClient.getTextIndexAtCursor();
      let range: inputMethodEngine.Range = {
        start: cursor,
        end: cursor
      };
      return range;
    } catch (_) {
      let fallbackRange: inputMethodEngine.Range = {
        start: 0,
        end: 0
      };
      return fallbackRange;
    }
  }
}
