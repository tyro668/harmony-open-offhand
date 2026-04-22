import directPinyinInputTest from './DirectPinyinInput.test';
import localUnitTest from './LocalUnit.test';
import pinyinNineKeyEngineTest from './PinyinNineKeyEngine.test';

export default function testsuite() {
  directPinyinInputTest();
  localUnitTest();
  pinyinNineKeyEngineTest();
}