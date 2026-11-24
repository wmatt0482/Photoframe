CREATE TABLE photos (
  id            TEXT PRIMARY KEY,
  created_at    INTEGER NOT NULL,
  caption       TEXT NOT NULL DEFAULT '',
  source        TEXT NOT NULL DEFAULT 'web',
  frame         BLOB NOT NULL,   -- 192,000 bytes, packed for the panel
  preview       BLOB NOT NULL,   -- small JPEG for the web app
  shown_count   INTEGER NOT NULL DEFAULT 0,
  last_shown_at INTEGER
);

CREATE TABLE kv (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);
