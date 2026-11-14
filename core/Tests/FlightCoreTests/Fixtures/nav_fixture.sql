-- A few real facilities from the FAA cycle of 2026-10-01, trimmed to a handful of rows each.

INSERT INTO meta(key, value) VALUES
  ('schema_version', '1'),
  ('cycle', '2026-10-01'),
  ('effective', '2026-10-01T09:01:00Z'),
  ('expires', '2026-10-29T09:01:00Z'),
  ('built_at', '2026-10-13T04:00:00Z');

INSERT INTO airports(id, site_no, ident, icao, name, city, state, type, use, lat, lon, elev, magvar, tpa, twr, fuel, artcc, status) VALUES
  (1, '23369.',   'AUS',  'KAUS', 'AUSTIN-BERGSTROM INTL',       'AUSTIN',         'TX', 'A', 'PU', 30.19452722,  -97.66987611,  541.5, '4E',  NULL, 'ATCT-TRACON', '100LL,A',         'ZHU', 'O'),
  (2, '23373.2',  'EDC',  'KEDC', 'AUSTIN EXEC',                 'AUSTIN',         'TX', 'A', 'PU', 30.39749313,  -97.5663935,   620.0, '5E',  NULL, 'ATCT',        '100LL,A+',        'ZHU', 'O'),
  (3, '23903.',   'T82',  NULL,   'GILLESPIE COUNTY',            'FREDERICKSBURG', 'TX', 'A', 'PU', 30.24324305,  -98.90918666, 1694.9, '6E',  NULL, 'NON-ATCT',    '100LL,A',         'ZHU', 'O'),
  (4, '23369.12', 'TX05', NULL,   'BUD DRYDEN',                  'AUSTIN',         'TX', 'A', 'PR', 30.26048611,  -97.62527777,  500.0, '6E',  NULL, 'NON-ATCT',    NULL,              'ZHU', 'O'),
  (5, '23369.25', '68TX', NULL,   'DELL SETON MEDICAL CENTER',   'AUSTIN',         'TX', 'H', 'PR', 30.27577777,  -97.73419444,  613.0, NULL,  NULL, 'NON-ATCT',    NULL,              'ZHU', 'O'),
  (6, '23933.',   'TS01', NULL,   'LANDRY',                      'GEORGETOWN',     'TX', 'A', 'PR', 30.71269083,  -97.65028694,  780.0, '7E',  NULL, 'NON-ATCT',    NULL,              'ZHU', 'CI'),
  (7, '50034.',   'ANC',  'PANC', 'TED STEVENS ANCHORAGE INTL',  'ANCHORAGE',      'AK', 'A', 'PU', 61.17408472, -149.9981375,   151.4, '16E', NULL, 'ATCT',        '100,100LL,A,A1',  'ZAN', 'O');

INSERT INTO runways(airport_id, rwy_id, length, width, surface, cond, lights) VALUES
  (1, '18L/36R',  9000, 150, 'CONC', 'GOOD', 'HIGH'),
  (1, '18R/36L', 12250, 150, 'CONC', 'GOOD', 'HIGH'),
  (2, '13/31',    6025, 100, 'ASPH', 'GOOD', 'MED'),
  (3, '14/32',    5002,  75, 'ASPH', 'GOOD', 'MED'),
  (4, '01/19',    2300,  60, 'TURF', '',     ''),
  (5, 'H1',         43,  43, 'DECK', '',     'PERI'),
  (6, '18/36',    1400,  30, 'GRVL', '',     ''),
  (7, '07L/25R', 10600, 150, 'ASPH', 'GOOD', 'HIGH');

INSERT INTO runway_ends(airport_id, rwy_id, end_id, true_hdg, rh_pattern, lat, lon, elev, displaced_len, vgsi, als, tora, lda) VALUES
  (1, '18L/36R', '18L', 179,  'N', 30.20383005,  -97.65789105,  491.6, NULL, 'P4L', 'ALSF2', 9000,  9000),
  (1, '18L/36R', '36R', 359,  'Y', 30.17909102,  -97.65724333,  473.6, NULL, 'P4L', 'MALSR', 9000,  9000),
  (1, '18R/36L', '18R', 179,  'Y', 30.21361613,  -97.67936477,  541.4, NULL, 'P4L', 'MALS',  12250, 12250),
  (1, '18R/36L', '36L', 359,  'N', 30.17994322,  -97.67847469,  487.3, NULL, 'P4L', 'MALS',  12250, 12250),
  (2, '13/31',   '13',  NULL, '',  30.40360555,  -97.57345833,  620.0, 600,  'P4L', '',      NULL,  NULL),
  (2, '13/31',   '31',  NULL, '',  30.39264444,  -97.55912777,  596.6, NULL, 'P4L', '',      NULL,  NULL),
  (3, '14/32',   '14',  147,  'Y', 30.24899233,  -98.91352972, 1694.9, NULL, 'P2L', '',      NULL,  NULL),
  (3, '14/32',   '32',  327,  'N', 30.23749383,  -98.90484391, 1677.4, NULL, 'P2L', '',      NULL,  NULL),
  (4, '01/19',   '01',  NULL, '',  NULL,         NULL,          NULL,  NULL, '',    '',      NULL,  NULL),
  (4, '01/19',   '19',  NULL, '',  NULL,         NULL,          NULL,  200,  '',    '',      NULL,  NULL),
  (5, 'H1',      'H1',  NULL, '',  30.27583055,  -97.73435,     613.0, NULL, '',    '',      NULL,  NULL),
  (7, '07L/25R', '07L', 90,   'Y', 61.16976497, -150.00833327,  127.7, NULL, 'P4R', 'MALSR', 10600, 10600),
  (7, '07L/25R', '25R', 270,  'N', 61.16981116, -149.94830072,   91.8, NULL, 'P4L', '',      10600, 10600);

INSERT INTO frequencies(airport_id, use, kind, freq, call, sector, remark) VALUES
  (1, 'RAMP CTL',            'other',     '126.225', 'AUSTIN',          '',     ''),
  (1, 'UNICOM',              'unicom',    '122.95',  '',                '',     ''),
  (1, 'APCH/P DEP/P IC',     'approach',  '127.225', 'AUSTIN',          'EAST', ''),
  (1, 'APCH/P DEP/P IC',     'approach',  '119.0',   'AUSTIN',          'WEST', ''),
  (1, 'D-ATIS',              'atis',      '124.4',   'AUSTIN',          '',     ''),
  (1, 'CD/P',                'clearance', '125.5',   'AUSTIN',          '',     ''),
  (1, 'GND/P',               'ground',    '121.9',   'AUSTIN',          '',     ''),
  (1, 'LCL/S',               'tower',     '118.225', 'AUSTIN',          '',     ''),
  (1, 'LCL/P',               'tower',     '121.0',   'AUSTIN',          '',     ''),
  (2, 'CTAF',                'ctaf',      '120.3',   '',                '',     'ACTVT REIL RWYS 13 & 31; MIRL RWY 13/31 - CTAF.'),
  (2, 'LCL/P',               'tower',     '120.3',   'EXECUTIVE TOWER', '',     ''),
  (2, 'GND/P',               'ground',    '119.45',  'EXECUTIVE TOWER', '',     ''),
  (2, 'EDC AWOS-3',          'weather',   '118.825', '',                '',     ''),
  (3, 'CTAF',                'ctaf',      '122.7',   '',                '',     'RWY 14/32 MIRL PRESET LOW INTST; TO INCR INTST ACTVT - CTAF.'),
  (3, 'UNICOM',              'unicom',    '122.7',   '',                '',     ''),
  (3, 'T82 AWOS-3',          'weather',   '120.0',   '',                '',     ''),
  (3, 'FREDERICKSBURG RCAG', 'other',     '134.2',   '',                'LOW',  'APCH/DEP CTL SVC PRVDD BY HOUSTON ARTCC (ZHU) ON FREQS 134.2/307.3 (FREDERICKSBURG RCAG).'),
  (5, 'UNICOM',              'unicom',    '123.05',  '',                '',     ''),
  (7, 'LCL/P',               'tower',     '118.3',   'ANCHORAGE',       '',     ''),
  (7, 'GND/P',               'ground',    '121.9',   'ANCHORAGE',       '',     ''),
  (7, 'D-ATIS',              'atis',      '135.5',   'ANCHORAGE',       '',     '');

INSERT INTO remarks(airport_id, tab, ref_col, element, seq, remark) VALUES
  (1, 'AIRPORT',    'GENERAL_REMARK', '',      14, 'TWY A CLSD TO ACFT WITH WINGSPAN MORE THAN 171 FT.'),
  (1, 'AIRPORT',    'GENERAL_REMARK', '',      1,  'BIRD ACTIVITY ON & INVOF ARPT.'),
  (1, 'AIRPORT',    'GENERAL_REMARK', '',      8,  'NOISE ABATEMENT: ALL DEP FOLLOW ATC INSTRUCTIONS; CLIMB ASAP TO 4000 FT OR ABOVE.'),
  (3, 'AIRPORT',    'GENERAL_REMARK', '',      5,  'FBO 830-997-3313.'),
  (3, 'FUEL_TYPE',  'FUEL_TYPE',      '100LL', 1,  'FUEL 24 HR SELF SERVE. FULL SERV AVBL DURING ATND HRS.'),
  (3, 'RUNWAY_END', 'CLOSE_IN_OBSTN', '14',    1,  '3 FT FENCE 190-200 FT FM THLD 216 FT RIGHT.'),
  (4, 'AIRPORT',    'GENERAL_REMARK', '',      1,  'FOR CD CTC AUSTIN APCH AT 512-269-7865.');

INSERT INTO navaids(id, ident, type, name, city, state, lat, lon, elev, freq, chan, magvar, status) VALUES
  (1, 'CWK', 'VORTAC', 'CENTEX',      'AUSTIN',      'TX', 30.37855, -97.52984722,  593.0, '112.8', '75X',  '6E', 'OPERATIONAL RESTRICTED'),
  (2, 'SAT', 'VORTAC', 'SAN ANTONIO', 'SAN ANTONIO', 'TX', 29.64403, -98.4613158,  1158.8, '116.8', '115X', '8E', 'OPERATIONAL RESTRICTED');

INSERT INTO fixes(id, ident, state, lat, lon, use, charts) VALUES
  (1, 'BITER', 'TX', 30.11251388, -97.07993055, 'WP', 'CONTROLLER LOW,ENROUTE LOW,STAR');

INSERT INTO airway_points(airway, location, seq, point, point_type, lat, lon, gap, mea) VALUES
  ('J21', 'C', 40, 'SAT', 'VORTAC', 29.64403, -98.4613158,  0, 18000),
  ('J21', 'C', 50, 'CWK', 'VORTAC', 30.37855, -97.52984722, 0, 18000);
