# إعداد رفع iOS إلى TestFlight (توقيع يدوي)

## 1) في Apple Developer
1. ادخل Certificates, Identifiers & Profiles.
2. من Identifiers أنشئ App ID (Explicit) للتطبيق.
3. من Certificates أنشئ شهادة Apple Distribution باستخدام CSR.
4. من Profiles أنشئ Provisioning Profile نوع App Store لنفس الـ Bundle ID.

## 2) في App Store Connect
1. من Apps أنشئ تطبيق جديد بنفس Bundle ID.
2. من Users and Access > Integrations > API Keys أنشئ API Key واحفظ:
   - Key ID
   - Issuer ID
   - ملف .p8

## 3) أسرار GitHub المطلوبة (Repository Secrets)
- APP_STORE_CONNECT_API_KEY_ID
- APP_STORE_CONNECT_ISSUER_ID
- APP_STORE_CONNECT_API_KEY_BASE64
- APPLE_TEAM_ID
- IOS_BUNDLE_ID
- IOS_CERTIFICATE_P12_BASE64
- IOS_CERTIFICATE_PASSWORD
- IOS_MOBILEPROVISION_BASE64

## 4) تشغيل الرفع
- اذهب إلى Actions > iOS TestFlight (Resident) > Run workflow.

> آخر تحديث CI: trigger-from-local-push
