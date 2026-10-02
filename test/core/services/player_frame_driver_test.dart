import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';

void main() {
  test('同一帧中被其他回调移除的订阅者不会再收到回调', () async {
    final driver = PlayerFrameDriver.instance;
    var removedCallbackCount = 0;
    void removeLater() => removedCallbackCount++;
    void remover() => driver.removeListener(removeLater);

    driver.addListener(remover);
    driver.addListener(removeLater);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 2);
      expect(removedCallbackCount, 0);
    } finally {
      driver.removeListener(remover);
      driver.removeListener(removeLater);
    }
  });
}
