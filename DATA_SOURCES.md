# Data Sources

This project uses real-world football data from third-party sources.
The code in this repository is MIT-licensed (see [LICENSE](./LICENSE)),
but the data itself is **not** — each source below carries its own terms.

This project is a non-commercial learning/portfolio project.

| Source | Used for | License / Terms | Link |
|---|---|---|---|
| OpenFootball | Initial bulk load (clubs, historical results) | Varies by sub-repo — verify before use | https://github.com/openfootball |
| Kaggle datasets | Initial bulk load (players, international results) | Varies by dataset author — verify before use | https://www.kaggle.com |
| StatsBomb Open Data | Analytics (optional, later phase) | StatsBomb open data license — attribution required, non-commercial | https://github.com/statsbomb/open-data |
| Wikidata / Wikipedia | Player biographies, reference data | CC0 | https://www.wikidata.org |
| football-data.org | Recurring live sync (results, standings) | Attribution required, terms vary by tier | https://www.football-data.org |
| API-Football (RapidAPI) | Additional live source (optional) | Own Terms of Service | https://www.api-football.com |
| TheSportsDB | Cross-checking / deduplication (optional) | Own terms, crowd-sourced | https://www.thesportsdb.com |

_This table will be updated as each source is actually integrated —
entries above marked "optional" or "later phase" are not yet in use._

## Notes

- Every ETL script that pulls from an external source should note the
  source and the date its license/terms were last checked in a header
  comment.
- Before redistributing or publishing any derived dataset, re-verify the
  license of the specific dataset version in use — terms can change
  independently of this document.
