import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/shareme_device_name.dart';
import 'package:test/test.dart';

void main() {
  test('names LocalSend made up are recognized in English and Chinese', () async {
    final en = (await AppLocale.en.build()).aliasGenerator;
    final zh = (await AppLocale.zhCn.build()).aliasGenerator;
    expect(await isGeneratedAlias(en.combination(adjective: en.adjectives.first, fruit: en.fruits.last)), isTrue);
    expect(await isGeneratedAlias(zh.combination(adjective: zh.adjectives.last, fruit: zh.fruits.first)), isTrue);
  });

  test('the user\'s own names are left alone', () async {
    for (final name in ['OFFICE-PC', 'Redmi Note 13 Pro', '小明的电脑', '书房电脑', '']) {
      expect(await isGeneratedAlias(name), isFalse, reason: name);
    }
  });
}
