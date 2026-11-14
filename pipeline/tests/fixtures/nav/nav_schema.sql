-- Navigation database, schema version 1. One file per 28-day FAA cycle.
-- Text columns hold the FAA's own codes and wording unless noted.

-- Required keys: schema_version ('1'), cycle (YYYY-MM-DD), and three UTC times
-- written like 2026-10-01T09:01:00Z: effective, expires, built_at.
CREATE TABLE meta(
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE airports(
  id      INTEGER PRIMARY KEY,
  site_no TEXT NOT NULL,
  ident   TEXT NOT NULL,  -- FAA identifier: AUS, T82, TX05
  icao    TEXT,           -- NULL when the FAA lists none; never derived from ident
  name    TEXT NOT NULL,
  city    TEXT NOT NULL,
  state   TEXT NOT NULL,
  type    TEXT NOT NULL,  -- A airport, H heliport, C water landing base, U ultralight, G glider, B balloon
  use     TEXT NOT NULL,  -- PU public, PR private
  lat     REAL NOT NULL,
  lon     REAL NOT NULL,
  elev    REAL,           -- feet MSL
  magvar  TEXT,           -- degrees and direction: 4E
  tpa     TEXT,           -- pattern altitude as published
  twr     TEXT NOT NULL,  -- NON-ATCT, or a value starting ATCT
  fuel    TEXT,
  artcc   TEXT,
  status  TEXT NOT NULL,  -- O operational, CI closed indefinitely, CP closed permanently
  ownership TEXT          -- PU public, PR private, MA Air Force, MN Navy, MR Army, CG Coast Guard
);
CREATE INDEX airports_ident ON airports(ident);
CREATE INDEX airports_icao ON airports(icao);

-- Both indexes below are filled by the trigger. A build inserts into airports only.
CREATE VIRTUAL TABLE airports_rtree USING rtree(id, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE airports_fts USING fts5(ident, icao, name, city, state,
  content='airports', content_rowid='id', prefix='1 2 3 4');
CREATE TRIGGER airports_index AFTER INSERT ON airports BEGIN
  INSERT INTO airports_rtree VALUES (new.id, new.lat, new.lat, new.lon, new.lon);
  INSERT INTO airports_fts(rowid, ident, icao, name, city, state)
    VALUES (new.id, new.ident, new.icao, new.name, new.city, new.state);
END;

CREATE TABLE runways(
  airport_id INTEGER NOT NULL,
  rwy_id     TEXT NOT NULL,  -- 18L/36R, or H1 for a helipad
  length     INTEGER,        -- feet; 0 or NULL when not published
  width      INTEGER,        -- feet; 0 or NULL when not published
  surface    TEXT,
  cond       TEXT,
  lights     TEXT
);
CREATE INDEX runways_a ON runways(airport_id);

CREATE TABLE runway_ends(
  airport_id    INTEGER NOT NULL,
  rwy_id        TEXT NOT NULL,
  end_id        TEXT NOT NULL,  -- 18L
  true_hdg      INTEGER,        -- degrees true
  rh_pattern    TEXT,           -- Y, N or empty
  lat           REAL,
  lon           REAL,
  elev          REAL,           -- feet MSL
  displaced_len INTEGER,        -- feet
  vgsi          TEXT,
  als           TEXT,
  tora          INTEGER,        -- feet
  lda           INTEGER         -- feet
);
CREATE INDEX ends_a ON runway_ends(airport_id);

-- use is the FAA's free text. kind sorts it into a short fixed list.
-- The rules are tried from the top and the first match wins:
--   weather    contains AWOS or ASOS
--   ctaf       is CTAF
--   unicom     is UNICOM
--   tower      starts with LCL/
--   ground     starts with GND/
--   clearance  starts with CD/ or with CD PRE
--   atis       is ATIS or D-ATIS
--   approach   starts with APCH/
--   departure  starts with DEP/
--   emergency  is EMERG
--   other      everything else
CREATE TABLE frequencies(
  airport_id INTEGER NOT NULL,
  use        TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('ctaf', 'unicom', 'tower', 'ground', 'clearance',
               'atis', 'approach', 'departure', 'weather', 'emergency', 'other')),
  freq       TEXT NOT NULL,  -- as published: 121.0
  call       TEXT,
  sector     TEXT,
  remark     TEXT
);
CREATE INDEX freq_a ON frequencies(airport_id);

CREATE TABLE remarks(
  airport_id INTEGER NOT NULL,
  tab        TEXT,
  ref_col    TEXT,
  element    TEXT,
  seq        INTEGER,
  remark     TEXT NOT NULL
);
CREATE INDEX rmk_a ON remarks(airport_id);

CREATE TABLE navaids(
  id     INTEGER PRIMARY KEY,
  ident  TEXT NOT NULL,
  type   TEXT NOT NULL,  -- VORTAC, VOR/DME, NDB ...
  name   TEXT NOT NULL,
  city   TEXT,
  state  TEXT,
  lat    REAL NOT NULL,
  lon    REAL NOT NULL,
  elev   REAL,           -- feet MSL
  freq   TEXT,
  chan   TEXT,
  magvar TEXT,           -- degrees and direction: 6E
  status TEXT
);
CREATE INDEX navaids_ident ON navaids(ident);

CREATE TABLE fixes(
  id     INTEGER PRIMARY KEY,
  ident  TEXT NOT NULL,
  state  TEXT,
  lat    REAL NOT NULL,
  lon    REAL NOT NULL,
  use    TEXT,
  charts TEXT            -- comma-separated chart types
);
CREATE INDEX fixes_ident ON fixes(ident);

-- One row per point along an airway, in order. lat and lon are NULL when the
-- point could not be placed; a line is broken there and after a row with gap = 1.
CREATE TABLE airway_points(
  airway     TEXT NOT NULL,     -- J21, V565
  location   TEXT NOT NULL,     -- C contiguous US, A Alaska, H Hawaii
  seq        INTEGER NOT NULL,
  point      TEXT NOT NULL,     -- fix or navaid identifier
  point_type TEXT,
  lat        REAL,
  lon        REAL,
  gap        INTEGER NOT NULL DEFAULT 0,
  mea        INTEGER            -- feet MSL
);
CREATE INDEX airway_points_a ON airway_points(airway, location, seq);

-- Obstacles of 200 ft above ground and taller, from the FAA daily obstacle file.
CREATE TABLE obstacles(
  id       INTEGER PRIMARY KEY,
  oas      TEXT NOT NULL,     -- FAA obstacle number: 48-001234
  type     TEXT,              -- TOWER, WINDMILL, BLDG ... as published
  lat      REAL NOT NULL,
  lon      REAL NOT NULL,
  agl      INTEGER NOT NULL,  -- feet above ground
  msl      INTEGER,           -- feet above sea level
  lighting TEXT,              -- the FAA's one-letter lighting code
  quantity INTEGER,           -- structures at this position
  verified TEXT               -- O verified, U unverified
);

-- Parachute jump areas, and aerobatic, glider, hang glider, ultralight and space launch areas.
CREATE TABLE activity_areas(
  id      INTEGER PRIMARY KEY,
  ident   TEXT NOT NULL,   -- FAA area id: PTX012, AAL001
  type    TEXT NOT NULL,   -- PARACHUTE, or the FAA's own name: AEROBATIC PRACTICE, GLIDER ...
  name    TEXT,
  lat     REAL NOT NULL,   -- the published point, or the middle of the published outline
  lon     REAL NOT NULL,
  max_alt TEXT,            -- as published: 12500 MSL, 5000AGL
  radius  TEXT,            -- nautical miles, as published
  hours   TEXT,
  airport TEXT,            -- FAA identifier of the field it belongs to
  charted INTEGER          -- 1 when the FAA asked for it on charts, 0 when not, NULL when not stated
);

-- Taxiways, aprons, buildings, FBOs and hold lines from OpenStreetMap (© OpenStreetMap contributors, ODbL),
-- per airport. points packs little-endian 16-bit pairs: feet east, then north, of the airport's lat and lon.
-- A polygon's ring is not closed; a point is one pair.
CREATE TABLE surface(
  airport_id INTEGER NOT NULL,
  kind       TEXT NOT NULL,  -- taxiway, taxilane, hold (line or point), apron, building, fbo (point)
  name       TEXT,           -- taxiway ref such as A or B2, or FBO name
  points     BLOB NOT NULL
);
CREATE INDEX surface_a ON surface(airport_id);
