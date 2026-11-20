# Native app setup (one time, about an hour, all in a browser and PowerShell)

The iPhone and Watch apps are built by GitHub Actions on Apple's Macs in the cloud and installed from **TestFlight**. These steps give GitHub what it needs to sign and upload the app. You only do them once.

Keep all keys, tokens and passwords to yourself. Type or paste them only into Apple's or GitHub's own pages, or into the PowerShell prompts below. Never put them in chat or in a file in this repo.

## 1. Find your Team ID
[developer.apple.com/account](https://developer.apple.com/account) → **Membership details** → copy the **Team ID** (10 characters).

## 2. Create the two app IDs
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → **+** → **App IDs** → **App** → Continue. Create these two:

| Description | Bundle ID (Explicit) | Capabilities to tick |
|---|---|---|
| 5K Coach | `com.jdszwarga.fivekcoach` | **HealthKit** |
| 5K Coach Watch | `com.jdszwarga.fivekcoach.watchkitapp` | **HealthKit** |

HealthKit isn't used yet. Ticking it now means the signing profiles won't need to be rebuilt when heart rate arrives.

## 3. Create the app in App Store Connect
[App Store Connect → Apps](https://appstoreconnect.apple.com/apps) → **+** → **New App**:
- Platform: **iOS**.
- Name: anything unique across the App Store, for example "5K Coach Szwarga". It's never shown publicly, and the home-screen name stays "5K Coach". If the name is taken, try another.
- Language: English (U.S.).
- Bundle ID: `com.jdszwarga.fivekcoach`.
- SKU: `fivekcoach`.
- User access: Full access.

Nothing is submitted for review. TestFlight internal testing doesn't need it.

## 4. Create an App Store Connect API key
[Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → **Team Keys** → **+**.
- Name: `GitHub Actions`. Access: **Admin**. Admin is needed so the first build can create the signing certificate.
- Note the **Issuer ID** (shown above the list) and the key's **Key ID**.
- **Download** the `AuthKey_XXXXXXXXXX.p8` file. Apple lets you download it only once. Keep it in Downloads for step 7, then store it somewhere safe outside this repo.

## 5. Create a private repo for the signing certificate
It's stored there encrypted. In PowerShell:

```powershell
gh repo create 5k-coach-certs --private
```

## 6. Create a GitHub token that can reach only that repo
[github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) (fine-grained token):
- Name: `5k-coach match`. Expiration: the longest offered. You'll need to renew it when it expires.
- Repository access: **Only select repositories** → `5k-coach-certs`.
- Permissions → Repository → **Contents: Read and write**.
- Generate, and copy the token. It's used in the next step.

## 7. Add the secrets to the 5k-coach repo
Run these one at a time in PowerShell, from this folder. Each `gh secret set` asks you for the value, so nothing ends up in your command history.

```powershell
gh secret set TEAM_ID --repo jdszwarga/5k-coach
```
```powershell
gh secret set ASC_KEY_ID --repo jdszwarga/5k-coach
```
```powershell
gh secret set ASC_ISSUER_ID --repo jdszwarga/5k-coach
```
Point the next command at your downloaded `.p8` file (replace `XXXXXXXXXX` with your Key ID):
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AuthKey_XXXXXXXXXX.p8")) | gh secret set ASC_KEY_P8_BASE64 --repo jdszwarga/5k-coach
```
Pick a long passphrase that encrypts the certificate repo, and save it in your password manager:
```powershell
gh secret set MATCH_PASSWORD --repo jdszwarga/5k-coach
```
```powershell
gh secret set MATCH_GIT_URL --repo jdszwarga/5k-coach --body "https://github.com/jdszwarga/5k-coach-certs.git"
```
Paste the token from step 6 when asked:
```powershell
$t = Read-Host "Paste the GitHub token" -AsSecureString; $p = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($t)); [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("jdszwarga:$p")) | gh secret set MATCH_GIT_BASIC_AUTHORIZATION --repo jdszwarga/5k-coach; Remove-Variable t, p
```

Check that all seven are there:
```powershell
gh secret list --repo jdszwarga/5k-coach
```

## 8. First build: creates the certificate and uploads build 1
```powershell
gh workflow run ios.yml --repo jdszwarga/5k-coach -f testflight=true -f create_signing=true
```
It takes about 20–30 minutes. Watch it on the repo's **Actions** tab. Later builds use `-f create_signing=false` (the default), or the **Run workflow** button there.

If it fails with a message about the maximum number of certificates, revoke an old **Apple Distribution** certificate you no longer use under Certificates, Identifiers & Profiles, then run it again.

## 9. Set up TestFlight for both of you
1. If the runner isn't on your team yet: [Users and Access](https://appstoreconnect.apple.com/access/users) → **+** → their name and Apple ID email → role **Customer Support** → Invite. They accept the email invite.
2. Your app → **TestFlight** → **Internal Testing** → **+** → group "Us". Turn on **Enable automatic distribution**, then add yourself and the runner.
3. On each iPhone, install **TestFlight** from the App Store, open the invite email, and install **5K Coach**.
4. Watch app: on the iPhone open the **Watch** app → scroll to **Available Apps** → **Install** next to 5K Coach. Or turn on automatic app install there.

## Keeping it installed
Each TestFlight build expires after 90 days. The workflow uploads a fresh build on the 1st of every month, and TestFlight updates the phones automatically, so it never runs out while the developer account is paid.

GitHub turns off scheduled workflows in public repos after 60 days without activity. The monthly run makes a small commit (`ios/LAST_REFRESH`) to prevent that. If GitHub ever emails that the schedule was disabled, re-enable it on the Actions tab.
