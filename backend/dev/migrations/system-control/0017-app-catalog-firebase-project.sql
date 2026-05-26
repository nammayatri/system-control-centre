-- Add firebase_project_id to app_catalog so each app can link to its
-- own Firebase Crashlytics project in the dashboard.
ALTER TABLE app_catalog ADD COLUMN IF NOT EXISTS firebase_project_id TEXT;

-- Set Firebase project IDs per app.
-- Replace 'namma-yatri' with the actual Firebase project ID for each app.
-- Both Android and iOS rows for the same app share the same project.
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'Cumta';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'NammaYatri';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'ManaYatri';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'Yatri';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'OdishaYatri';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'YatriSathi';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'KeralaSavaari';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'Bridge';
UPDATE app_catalog SET firebase_project_id = 'movingtech-155ad' WHERE name = 'BharatTaxi';
UPDATE app_catalog SET firebase_project_id = 'namma-yatri' WHERE name = 'Lynx';
