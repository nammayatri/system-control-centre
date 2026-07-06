-- 0033-app-store-account.sql
-- Multi-account App Store Connect. Some apps live in a different Apple account than
-- the default one SCC's SC_ASC_* key belongs to, so the default key gets
-- asc_app_not_found / 403 for them. Tag those apps so SCC reads each with the right
-- key (env SC_ASC_*_<ACCOUNT>, uppercased); NULL = the default (unsuffixed) key.
--
-- Account split is authoritative from nammayatri/ny-react-native
-- .github/workflows/fastlane.yaml (key_id_map / issuer_map): everything is the
-- default account EXCEPT Cumta and YatriSathi.

ALTER TABLE app_catalog ADD COLUMN IF NOT EXISTS store_account TEXT;

UPDATE app_catalog SET store_account = 'cumta'      WHERE name = 'Cumta';
UPDATE app_catalog SET store_account = 'yatrisathi' WHERE name IN ('YatriSathi', 'YatriSathiDriver');
