-- Adds metadata URI, website URL, X/Twitter URL, and short description to launcher coins.
ALTER TABLE launcher_coins ADD COLUMN metadata_uri TEXT NOT NULL DEFAULT '';
ALTER TABLE launcher_coins ADD COLUMN website_url TEXT NOT NULL DEFAULT '';
ALTER TABLE launcher_coins ADD COLUMN twitter_url TEXT NOT NULL DEFAULT '';
ALTER TABLE launcher_coins ADD COLUMN description TEXT NOT NULL DEFAULT '';
