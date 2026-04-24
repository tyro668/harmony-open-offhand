import directPinyinInputTest from './DirectPinyinInput.test';
import englishEngineTest from './EnglishEngine.test';
import localUnitTest from './LocalUnit.test';
import pinyinNineKeyEngineTest from './PinyinNineKeyEngine.test';

export default function testsuite() {
  directPinyinInputTest();
  englishEngineTest();
  localUnitTest();
  pinyinNineKeyEngineTest();
}
