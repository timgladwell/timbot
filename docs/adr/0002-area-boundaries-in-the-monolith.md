# 2. Area boundaries in the monolith

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Tim Gladwell

## Context

timbot is one Rails application holding several unrelated areas: small
automations, and custom apps incubated here until they are ready to be split out
(water levels is the first). Areas must stay well-encapsulated. Keeping them that
way should be easy, and splitting one out later should be cheap.

At the start there is exactly one area. Structure added now would be designed
without a second area to test it against.

## Decision

### Plain Rails layout, one module namespace per area

Each area is a top-level Ruby module, using the standard Rails directories and
generators:

```
app/models/water_levels.rb              # module WaterLevels (table_name_prefix)
app/models/water_levels/station.rb      # WaterLevels::Station
app/controllers/water_levels/...        # WaterLevels::StationsController
app/jobs/water_levels/...               # WaterLevels::SweepJob
```

- `rails generate model water_levels/station` produces this shape, including the
  module file with `table_name_prefix`.

### Tables must be namespaced by area

Every table belongs to exactly one area and **must** carry that area's prefix,
set by the area module's `table_name_prefix`: `water_levels_stations`, never
`stations`. This is the Rails-native mechanism. The generator writes it, and
associations, fixtures, `schema.rb` and migrations all follow it with no extra
configuration. Framework tables that are already prefixed (`solid_queue_*`,
`active_storage_*`) are left as they are.

All areas share one database (ADR 0001). The prefix is what makes table ownership
visible, keeps a later move to a separate database or schema mechanical, and
gives packwerk something to check against.
- Routes use `namespace :water_levels`.
- Shared, area-agnostic code (`ApplicationRecord`, `ApplicationJob`, layouts)
  stays top-level.

No Rails engines, no alternative directory layout, no extra gems.

### Enforcement: packwerk, introduced with the second area

Boundaries are convention-only while there is one area, because there is
nothing to cross. Adding the second area is the trigger to adopt
[packwerk](https://github.com/Shopify/packwerk) and run `packwerk check` in CI.
Adopting it means answering the layout question below.

## Consequences

### Positive

- Nothing to learn or maintain beyond standard Rails. Generators work unmodified.
- Every constant and table already says which area owns it, which is the
  information packwerk will need.

### Negative / risks

- **An area is spread across `app/*` directories rather than living in one.**
  A packwerk package is a directory, so adopting packwerk will likely mean
  moving each area into its own directory (an in-repo engine, or a packs
  layout). Because constants are already namespaced, that move changes file
  paths, not code references. The choice between engines and packs is made
  then, with two real areas to compare. Packwerk's README recommends engines
  over packs-rails for autoloading.
- **Unenforced until then.** A cross-area reference slipped in before packwerk
  will surface as a violation to fix, or record, at adoption.

## Alternatives considered

| Option | Rejected because |
| --- | --- |
| In-repo Rails engine per area | A gemspec, engine class and isolated namespace per area before there's a second one to justify it. Engines run in-process, so memory was not the deciding factor. Reconsider when packwerk is adopted. |
| `packs-rails` layout (`packs/<area>/app/...`) | Non-standard layout plus a third-party gem, for a single area. |
| packwerk from day one | With one area there are no boundaries to check. |
| Postgres schema per area (`water_levels.stations`) | Rails support is partial: schema search paths, `schema.rb` dumping and fixtures all need extra care, and some cases force `structure.sql`. Table prefixes give the same visible ownership with none of that. |
| No namespacing | Leaves nothing for packwerk to build on and makes a later split-out a rename exercise. |
