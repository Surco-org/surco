-- Write-once off-chain metadata attachment table for factories without on-chain metadataURI (TEST factory).
-- Avoids any race between immediate post-launch attachment and the 5-block indexer settle delay.
CREATE TABLE launcher_coin_meta (
  factory TEXT NOT NULL,
  coin TEXT NOT NULL,
  metadata_uri TEXT NOT NULL DEFAULT '',
  website_url TEXT NOT NULL DEFAULT '',
  twitter_url TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (factory, coin)
);
