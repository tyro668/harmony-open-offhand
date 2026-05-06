import { describe, it, expect } from '@ohos/hypium';
import { EnglishEngine } from '../main/ets/ime/engine/english/EnglishEngine';

export default function englishEngineTest() {
  describe('EnglishEngine', () => {
    it('preserveShiftUppercaseInput', 0, () => {
      let engine = new EnglishEngine();
      let state = engine.typeText('A', false);
      state = engine.typeText('B', false);

      expect(state.composingText).assertEqual('AB');
      expect(state.candidates[0].text).assertEqual('AB');

      state = engine.processSpace(false);
      expect(state.commitText).assertEqual('AB ');
    });

    it('commitsPunctuationWithoutImplicitSpace', 0, () => {
      let engine = new EnglishEngine();
      let state = engine.typeText('A', false);
      state = engine.typeText('B', false);
      state = engine.processPunctuation('.', false);

      expect(state.commitText).assertEqual('AB.');
      expect(state.composingText).assertEqual('');
      expect(state.candidates.length).assertEqual(0);
    });

    it('keepsAutoCapitalizeForLowercaseInput', 0, () => {
      let engine = new EnglishEngine();
      let state = engine.typeText('h', true);

      expect(state.composingText).assertEqual('H');
      expect(state.candidates[0].text).assertEqual('H');
    });
  });
}
