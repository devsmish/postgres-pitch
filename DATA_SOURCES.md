# Data Sources

This project uses real-world football data from third-party sources.
The code in this repository is MIT-licensed (see [LICENSE](./LICENSE)),
but the data itself is **not** — each source below carries its own terms.

This project is a non-commercial learning/portfolio project.

Licenses and sizes below were checked on **2026-11-11** (issue #26) against
the upstream repositories at the commits listed in
[Snapshot](#snapshot-what-the-numbers-were-measured-on). Upstream data keeps
changing, so the sizes are a baseline for the initial load, not a promise.

## Selected for the initial load (Iteration 2)

The baseline uses only sources under an explicit open license (CC0 or
CC BY-SA 4.0).

| Source | What we take | License (checked) | Measured size |
|---|---|---|---|
| OpenFootball country repos in the Football.TXT format: [england](https://github.com/openfootball/england), [deutschland](https://github.com/openfootball/deutschland), [espana](https://github.com/openfootball/espana), [italy](https://github.com/openfootball/italy), [europe](https://github.com/openfootball/europe) | Club leagues and cups: the primary, most complete OpenFootball input | CC0 1.0 (`LICENSE.md` in each) | England alone: 1888-89 to 1892-93 (about 950 matches), 1992-93 to 1999-00 (partial, about 6,600), 2000-01 to 2009-10 (20,360), then tiers 1 to 4 for every season, tier 5 from 2015-16 |
| [openfootball/football.json](https://github.com/openfootball/football.json) | The same data, generated from the TXT files; used as a cross-check | CC0 1.0 (`LICENSE.md`) | 96,201 match rows, 44 competition codes, 2010-11 to 2026-27, **with gaps** (see below) |
| [martj42/international_results](https://github.com/martj42/international_results) (also on Kaggle) | National-team matches, goal scorers, penalty shoot-outs | CC0 1.0 (`LICENSE`) | 49,940 matches (1872-11-30 to 2026-10-06), 47,914 goals, 700 shoot-outs |
| [jfjelstul/worldcup](https://github.com/jfjelstul/worldcup) (Fjelstul World Cup Database) | World Cup players (with birth dates), squads (positions), goals, bookings, substitutions, referees | **CC BY-SA 4.0** (`README.md`, `DESCRIPTION`), see conditions below | per its README: 22 men's tournaments (1930-2022), 9 women's (1991-2019), 27 datasets; not counted here |

### Fjelstul World Cup Database: conditions

CC BY-SA 4.0 asks for attribution and share-alike. The attribution has four
parts: the author ("Joshua C. Fjelstul, Ph.D."), the notice "© 2023 Joshua C.
Fjelstul, Ph.D.", a link to the license
(<https://creativecommons.org/licenses/by-sa/4.0/legalcode>) and a link to the
repository (<https://www.github.com/jfjelstul/worldcup>), plus a statement of
any modifications. Share-alike means that a database or dump derived from this
data, if it is ever published, must carry the same license. Nothing derived
from it is published now. The author coded the data from Wikipedia pages and
cross-checked it with FIFA match reports.

### Why Football.TXT and not football.json

The JSON files are generated from the TXT files and are not complete. For the
seasons from 2010-11 on, about 18,700 matches exist only in the TXT files
(a regex count, so approximate; for a 24-team league it gives the expected 552
matches per season). Examples: English tiers 2 to 4 in 2016-17, 2017-18 and
(tiers 3 and 4) 2021-22 to 2023-24; the whole fifth tier from 2015-16; the German
3. Liga 2021-22 to 2025-26; the Spanish and Italian second tiers 2021-22 to
2023-24; the lower tiers of 2024-25 in Germany and Italy. The TXT files of the
`europe` repository were not counted, and the JSON files also carry competitions
from OpenFootball repositories that were not inspected here (Argentina, Brazil,
China, Japan, Mexico, the USA, ...); for those, only the JSON was looked at.

The 96,201 JSON rows exclude the three `*-full` files (`en.1-full`,
`de.1-full`, `at.1-full`, 881 rows), which repeat 2025-26 matches. 89,706 rows
have a final score. The other 6,495 are fixtures not played yet (5,888),
cancelled (585), postponed (21) or abandoned (1). #27 decides how it reads the
two formats; the recommendation of #26 is to parse Football.TXT as the primary
input.

## Selected, pending a coverage check

| Source | What we would take | License (checked) | Open question |
|---|---|---|---|
| [Wikidata](https://www.wikidata.org) (SPARQL or dumps) | Players (birth date, nationality, position, height), clubs, stadiums, career periods per club | CC0 for the structured data (<https://www.wikidata.org/wiki/Wikidata:Licensing>) | How complete these fields are for footballers. The property "member of sports team" (P54) is used about 2.08 M times on 1.78 M items across all sports (a property report of unknown date). Not measured for football; the query service is not reachable from the sandbox, so it has to run on a developer machine before #28. |

Wikidata does not hold match results or match events.

## Optional, not in the baseline

### Transfermarkt dataset

[dcaribou/transfermarkt-datasets](https://github.com/dcaribou/transfermarkt-datasets)
(also on Kaggle): clubs, players, transfers with fees, match events and the
matches they refer to. Per its README: 65 competitions, 790+ clubs, 50,000+
players, 88,000+ games, 1.27 M game events, 175,000+ transfers. The license of
the repository is CC0 1.0, but the dataset is scraped from Transfermarkt, and
a CC0 label on the repository does not settle the rights of the site the rows
were scraped from. We could not confirm them:

- The Kaggle page of the dataset could not be read here, so its license field is
  **unverified**; one third-party mirror lists it as "Other".
- In 2018 Transfermarkt reportedly told the author of an R package that its data
  is copyrighted under German law and has no license (quoted second-hand on the
  [R-package-devel mailing list](https://stat.ethz.ch/pipermail/r-package-devel/2018q1/002405.html)).
  We did not find Transfermarkt's current terms.
- The maintainer paused updates: the data ends on 2026-07-06 and there is no
  date for resuming. It is a frozen snapshot, which is enough for a one-off
  load but not a basis for the recurring sync.

If it is ever adopted, the conditions are: the data goes only into the private
development database; no row-level data from it is committed or published in
dumps, backups, screenshots or demo links; it is not redistributed. It is the
only source found for transfer fees. Not measured (needs the download): the
date range per competition and the overlap with OpenFootball. The decision is
made in #28, after the Wikidata check.

### StatsBomb Open Data

[statsbomb/open-data](https://github.com/statsbomb/open-data): the only source
found for events of club matches. Deferred on 2026-11-11 by decision of the
project owner; revisit if event data for club matches is wanted.

Its terms (the Public Data User Agreement, `LICENSE.pdf`, read in full): the
data is for analysis and research; the user may not reproduce, sell or provide
it to any third party, and may not exploit it commercially; any published
analysis must carry the StatsBomb logo; users are asked to register their name
and e-mail at statsbomb.com. Coverage by `competitions.json`: 80
competition-seasons with events and lineups per match, for example La Liga
1973/74 to 2020/21 (18 seasons), Champions League 1970/71 to 2018/19 (18),
Premier League 2003/04 and 2015/16, Serie A 1986/87 and 2015/16, Bundesliga
2015/16 and 2023/24, World Cups from 1958, and several women's competitions.
Event volume was not measured. Only goals, cards and substitutions would fit
the current `match_events` types.

## Evaluated and not used

| Source | Decision | Reason |
|---|---|---|
| [football-data.co.uk](https://www.football-data.co.uk) | Not used | Free CSV files back to 1993/94, but the site claims copyright on them and we found no license. Based on third-party descriptions; the site's own terms were not read. |
| [Flashscore](https://www.flashscore.com) / MyScore | Not used | The terms of use (read as search excerpts) forbid scraping, aggregating and recreating the content without consent, commercial use, and load from automated requests. |
| [Sofascore](https://www.sofascore.com) | Not used | No official API and no license; according to a third-party scraper's description of its FAQ, API access is not licensed because of agreements with data providers. The site's own terms were not read. |
| [engsoccerdata](https://github.com/jalapic/engsoccerdata) | Not used | The R package says GPL (>= 2), but its list of sources includes football-data.co.uk, ESPN and worldfootball.net, so the label does not clear the rights of the underlying data. It is the only source found for English leagues 1893-1992, which stays a gap. |
| [footballcsv/en-england](https://github.com/footballcsv/en-england) | Not needed | CC0, but a 1:1 CSV mirror of `openfootball/england`. |
| [FiveThirtyEight SPI](https://github.com/fivethirtyeight/data/tree/master/soccer-spi) | Not needed | The repository is CC BY 4.0, but the match files start in 2016, which OpenFootball already covers. |
| [football-data.org](https://www.football-data.org) | Later: Iteration 6 (recurring sync) | The free tier covers 12 competitions, the current season only, 10 requests per minute. It is not a source of history. Its terms ask for the attribution "Football data provided by the Football-Data.org API" (terms dated 2018-06-01). |

OpenFootball `worldcup` and `worldcup.json` (CC0) are not loaded either:
they describe matches that `international_results` already has, and
Fjelstul adds the players and events. They stay available as a cross-check.

## Not evaluated in #26

API-Football (own Terms of Service) and TheSportsDB (own terms,
crowd-sourced) stay as before; neither is in use. Evaluate each when it is
first integrated.

## Scope

- **Date range of the data: 1872-11-30 to 2027-05-30.** The first date is the
  first match in `international_results`. The last one is the latest fixture in
  `football.json` (the 2026-27 season). Input for #25: yearly partitions for
  every year from 1872 to 2027, 156 per partitioned table. The default
  partition stays as the catch-all.
- **Everything the selected sources contain is loaded**, including fixtures
  not played yet (they carry the status `scheduled`).
- **One source owns each (competition, season).** Club matches come from
  OpenFootball only. National-team matches come from `international_results`
  only; Fjelstul adds players and events and is linked to those matches by
  date and teams. For World Cup events both `international_results` (goals)
  and Fjelstul (goals, cards, substitutions) have data; #28 picks one.
- **What the baseline cannot fill:** events of club matches (no open source
  without conditions), transfers and fees (`player_career.fee_*` stays mostly
  empty), and English leagues 1893-1992. `match_events` therefore holds
  national-team matches only. Player careers depend on the Wikidata check.

## Known quirks of the inputs (for #27 and #28)

Measured on the snapshot below.

- `football.json`: the `score` field comes in five shapes: an object with
  `ft` (and `ht`), an object with `et` and `p` for extra time and penalties, an
  empty object, a bare two-element list, or missing. A `status` field holds
  `cancelled`, `canceled` (both spellings), `postponed`, `abandoned` or
  `awarded` (the last one has a score).
- `football.json`: 12 rows in `en.4` (2025-26, round 24) appear twice (the same
  date, teams and round). The loader has to be idempotent on the natural key.
- `football.json`: the kick-off `time` has no time zone, and 3,997 of the 96,201
  rows have no time at all, while `matches.match_date` is `TIMESTAMPTZ`.
- `football.json`: clubs are plain names, with no country field: the country has
  to be derived from the competition code. The Champions League names carry a
  country suffix, for example `Atlético Madrid (ESP)`. There are no goals,
  lineups or club metadata.
- `football.json`: some competitions are played within one calendar year
  (`2019`, `2025`, ...), so `year_start` equals `year_end` for them.
- Football.TXT: lines carry no year; it comes from the season header. The layout
  changed over time: older files put the score between the team names
  (`Team  2-2 (2-2)  Team`), newer ones write `Team v Team 4-2 (1-0)`.
- `international_results`: goal scorers are names with a minute, without ids, so
  they have to be matched to `players`.

## Snapshot: what the numbers were measured on

Shallow clones of the default branches, 2026-11-11.

| Repository | Commit | Commit date |
|---|---|---|
| openfootball/football.json | `e6744429ee` | 2026-09-22 |
| openfootball/england | `9ee7a0c351` | 2026-10-15 |
| openfootball/deutschland | `c34532ab69` | 2026-09-21 |
| openfootball/espana | `80035a93dd` | 2026-10-15 |
| openfootball/italy | `48954d163c` | 2026-09-21 |
| openfootball/europe | `63df627f3c` | 2026-10-15 |
| openfootball/worldcup | `25260b1d62` | 2026-10-21 |
| openfootball/worldcup.json | `516d3825c3` | 2026-08-11 |
| martj42/international_results | `b0948cb558` | 2026-10-31 |
| dcaribou/transfermarkt-datasets | `e44f186d6f` | 2026-09-05 |

The licenses of these ten repositories were read from their `LICENSE` files
(CC0 1.0 Universal). Not cloned, so without a commit: for `jfjelstul/worldcup`
the `README.md` and `DESCRIPTION` (version 1.2.0) and for `statsbomb/open-data`
the `README.md`, `LICENSE.pdf` and `competitions.json` were read from the
default branch on the same day. The loaders must not read "latest": they pin a
commit or a dated release of the data they load (decided in #27).

## Notes

- Every ETL script that pulls from an external source should note the
  source and the date its license/terms were last checked in a header
  comment.
- Before redistributing or publishing any derived dataset, re-verify the
  license of the specific dataset version in use — terms can change
  independently of this document.
