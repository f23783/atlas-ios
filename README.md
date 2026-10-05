# atlas-ios

Atlas Live'ın iPhone tarafı. Şimdilik yalnız **AtlasProbe**: ücretsiz Apple hesabıyla imzalanmış (SideStore/iLoader)
bir uygulamada iki şeyi kanıtlar:

1. **Ekran kilitliyken mikrofon** çalışıyor mu (`UIBackgroundModes: audio`)
2. **Kestirme çalıştırıp geri dönme** (`shortcuts://x-callback-url/run-shortcut` → `atlasprobe://`) ve sonuç geliyor mu

Mac yok: `project.yml` (XcodeGen) burada yazılır, GitHub Actions'ın macOS sunucusu `.xcodeproj` üretip **imzasız IPA**
derler (`build-ipa` iş akışı, artifact `AtlasProbe-ipa`). İmzayı telefona kurulurken iLoader/SideStore atar.
