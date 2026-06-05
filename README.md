# Bom-KaosKaki v3.0

All-in-One Penetration Testing Suite — Authorized Use Only.

## ⚡ Quick Start (5 Minutes)

### 1. Setup Firebase
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Create project → Firestore Database → Create (start in test mode)
3. Project Settings → Service Accounts → Generate new private key
4. Save as `firebase/serviceAccount.json`

### 2. Generate RSA Keys
```bash
openssl genrsa -out keys/private.pem 4096
openssl rsa -in keys/private.pem -pubout -out keys/public.pem