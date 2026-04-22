import { describe, it, expect } from '@ohos/hypium';
import { PinyinNineKeyEngine } from '../main/ets/ime/engine/pinyin/PinyinNineKeyEngine';

export default function pinyinNineKeyEngineTest() {
  describe('PinyinNineKeyEngine', () => {
    it('resolveCommonNineKeyPhrase', 0, () => {
      let engine = new PinyinNineKeyEngine();
      let state = engine.appendDigit('6');
      state = engine.appendDigit('4');
      state = engine.appendDigit('4');
      state = engine.appendDigit('2');
      state = engine.appendDigit('6');

      expect(state.activeSpelling).assertEqual('nihao');
      expect(state.spellings.join(' ')).assertContain('nihao');
    });

    it('syncRawInputIntoDigitSequence', 0, () => {
      let engine = new PinyinNineKeyEngine();
      let state = engine.syncWithRawInput('zhong');

      expect(state.digitSequence).assertEqual('94664');
      expect(state.activeSpelling).assertEqual('zhong');
    });

    it('allowManualSpellingSelectionAndBackspace', 0, () => {
      let engine = new PinyinNineKeyEngine();
      let state = engine.syncWithRawInput('nihao');
      state = engine.selectSpelling('mihao');

      expect(state.activeSpelling).assertEqual('mihao');
      expect(state.spellings.join(' ')).assertContain('nihao');

      state = engine.backspace();
      expect(state.digitSequence).assertEqual('6442');
    });

    it('resolveXihuForNineKeyPhraseInput', 0, () => {
      let engine = new PinyinNineKeyEngine();
      let state = engine.appendDigit('9');
      state = engine.appendDigit('4');
      state = engine.appendDigit('4');
      state = engine.appendDigit('8');

      expect(state.spellings.join(' ')).assertContain('xihu');

      state = engine.selectSpelling('xihu');
      expect(state.activeSpelling).assertEqual('xihu');
    });

    it('resolveJijieForNineKeyPhraseInput', 0, () => {
      let engine = new PinyinNineKeyEngine();
      let state = engine.appendDigit('5');
      state = engine.appendDigit('4');
      state = engine.appendDigit('5');
      state = engine.appendDigit('4');
      state = engine.appendDigit('3');

      expect(state.spellings.join(' ')).assertContain('jijie');

      state = engine.selectSpelling('jijie');
      expect(state.activeSpelling).assertEqual('jijie');
    });
  });
}
