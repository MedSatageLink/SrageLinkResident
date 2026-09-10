# دليل نشر تطبيق المقيم StageLink Resident على Google Play (من الصفر حتى النشر الرسمي)

هذا الملف عملي بالكامل: اتبع الخطوات بالترتيب و انسخ/الصق كما هي.

---

## 0) ما الذي تم تجهيزه مسبقًا داخل المشروع

تم تجهيز إعدادات أندرويد الأساسية للنشر في:
- `applicationId`: `com.stagelink.resident`
- `namespace`: `com.stagelink.resident`
- اسم التطبيق على الجهاز: `StageLink Resident`
- تفعيل إعدادات `release` مع `R8/Proguard` وتصغير الحجم
- إضافة ملف مثال للتوقيع: `android/key.properties.example`
- تأمين git بعدم رفع أسرار التوقيع (`.jks` و `key.properties`)

> مهم: لا تغيّر `applicationId` بعد أول إصدار منشور.

---

## 1) المتطلبات قبل البدء

1. حساب Google Play Developer مفعل.
2. سياسة خصوصية منشورة على رابط عام (HTTPS).
3. بيئة Flutter + Android SDK + Java 17 جاهزة.
4. أيقونة وهوية بصرية للتطبيق.

---

## 2) إنشاء مفتاح التوقيع (Upload Key)

من جذر مشروع المقيم `stagelink_resident`:

```powershell
Set-Location "d:\med\stagelink_resident"
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

احفظ كلمة المرور في مدير كلمات مرور.

---

## 3) ربط المفتاح مع المشروع

### 3.1 أنشئ ملف `android/key.properties`

```powershell
Copy-Item "d:\med\stagelink_resident\android\key.properties.example" "d:\med\stagelink_resident\android\key.properties"
```

عدّل الملف `android/key.properties`:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=../../upload-keystore.jks
```

---

## 4) تحديث رقم الإصدار قبل كل رفع

في `pubspec.yaml` عدّل:

```yaml
version: 1.0.0+8
```

مثال تحديث:

```yaml
version: 1.0.1+9
```

> يجب زيادة رقم `+` في كل إصدار جديد على Play.

---

## 5) بناء AAB رسمي

```powershell
Set-Location "d:\med\stagelink_resident"
flutter clean
flutter pub get
flutter build appbundle --release
```

موقع الملف:

```text
build\app\outputs\bundle\release\app-release.aab
```

---

## 6) إنشاء التطبيق في Play Console

1. Create app
2. App name: **StageLink Resident**
3. اللغة الافتراضية
4. App
5. Free أو Paid
6. أكمل التعهدات

---

## 7) نصوص المتجر (جاهزة للنسخ)

## اسم التطبيق

```text
StageLink Resident
```

## وصف قصير (<= 80 حرف)

```text
تطبيق المقيم لإدارة التدريب السريري والمهام والمتابعة الأكاديمية اليومية.
```

## وصف كامل

```text
StageLink Resident تطبيق احترافي لدعم الأطباء المقيمين في إدارة التدريب السريري والمهام اليومية بكفاءة.

أهم الميزات:
- متابعة المهام والأنشطة التدريبية.
- تنظيم سير العمل اليومي داخل البرنامج التدريبي.
- تتبع التقدم وتحسين الالتزام بالمتطلبات.
- تجربة استخدام موثوقة وسريعة.

نعمل باستمرار على تحسين التطبيق وإضافة مزايا تدعم المقيم والمؤسسة التعليمية.

للدعم الفني:
[PUT_SUPPORT_EMAIL]
```

---

## 8) الأصول المطلوبة للمتجر

- App icon: 512x512 PNG
- Feature graphic: 1024x500 PNG
- على الأقل 2 لقطات شاشة للهاتف (يفضل 4-8)
- (اختياري) صور للأجهزة اللوحية

---

## 9) سياسة الخصوصية

استخدم صفحة عامة (HTTPS). قالب مبدئي:

```text
Privacy Policy - StageLink Resident

StageLink Resident processes only the data needed to provide residency training workflows, account access, attendance/task tracking, and security.

Possible data categories:
- Account information provided by the institution
- Device/app technical identifiers for security and reliability
- Bluetooth/network related permissions for workflow features where enabled

We do not sell personal data.

Contact: [PUT_SUPPORT_EMAIL]
Last updated: [PUT_DATE]
```

---

## 10) Play Console Compliance

## 10.1 Data safety
- صرّح فقط بما يجمعه التطبيق فعليًا.
- غالبًا: حساب المستخدم + معرّفات تقنية + تشفير النقل.

## 10.2 App content
- Privacy policy URL: إلزامي
- Ads: No (إن لم توجد إعلانات)
- Target audience: حدده بدقة

## 10.3 تبرير الصلاحيات الحساسة (عند الطلب)

```text
The app uses Bluetooth permissions to enable institution-approved training workflows and attendance/proximity features. On older Android versions, location permission may be requested only for Bluetooth scan compatibility and is not used for continuous location tracking.
```

---

## 11) مسار النشر الصحيح

1. Internal testing
2. Create release
3. Upload AAB
4. Release notes (جاهزة):

```text
Initial production-ready release for StageLink Resident with stability and performance improvements.
```

5. Publish internal
6. اختبار كامل على جهاز حقيقي
7. بعدها Production > Create release > Submit for review

---

## 12) Checklist قبل الإرسال النهائي

- [ ] AAB جاهز بدون أخطاء
- [ ] `versionCode` مرفوع
- [ ] سياسة الخصوصية مضافة
- [ ] Data safety مكتمل
- [ ] App content مكتمل
- [ ] صور المتجر مكتملة
- [ ] اختبار داخلي ناجح

---

## 13) بعد النشر

- راقب الأعطال في Android vitals
- راقب التقييمات
- عند أي تحديث: ارفع `versionCode` وابنِ AAB جديد

---

## 14) أوامر سريعة (نسخ/لصق)

```powershell
Set-Location "d:\med\stagelink_resident"
flutter clean
flutter pub get
flutter build appbundle --release
```

```text
AAB Path:
build\app\outputs\bundle\release\app-release.aab
```

---

## 15) حل خطأ: failed to strip debug symbols

إذا ظهر هذا الخطأ، السبب غالبًا أن مسار Android SDK يحتوي مسافات.

الحل الأفضل (نهائي):
1. انقل Android SDK إلى مسار بدون مسافات مثل: `D:\Android\Sdk`
2. حدّث متغير النظام `ANDROID_HOME` إلى المسار الجديد
3. حدّث `android/local.properties` ليكون:

```properties
sdk.dir=D:\\Android\\Sdk
flutter.sdk=D:\\flutter_windows_3.32.8-stable\\flutter
```

4. أعد البناء.

مؤقتًا: تم تفعيل إعداد يمنع stripping للملفات الأصلية، لذلك قد يتم إنشاء AAB صالح لكن بحجم أكبر قليلًا.
