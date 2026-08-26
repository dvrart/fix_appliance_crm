# Правила ProGuard/R8 для Twilio Voice SDK.
# Нужны только при включённой минификации релизной сборки (minifyEnabled true).
-keep class com.twilio.** { *; }
-keep class tvo.webrtc.** { *; }
-dontwarn tvo.webrtc.**
-keep class com.twilio.voice.** { *; }
-keep class org.json.** { *; }
-keepnames class org.json.** { *; }
-keepattributes InnerClasses

# Stripe Terminal / Tap to Pay
-keep class com.stripe.** { *; }
-dontwarn com.stripe.**
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# ML Kit text recognition: optional language packs are not bundled.
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
