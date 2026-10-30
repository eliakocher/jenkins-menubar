# GitLab fixtures

Answer bodies of GitLab's GraphQL API (`POST /api/graphql`), read by the tests in
`Tests/MenubarCoreTests/GitLab/`.

## Real answers, sanitized

Taken on 2026-10-28 from the old tool's `~/Library/Logs/jenkins-menubar/requests/` (GitLab 19.3.6-ee), or from an
anonymous request without a token. Sanitized: the host is `gitlab.example.com`, the project `acme/main/server/server`,
people, customers and squads are made up, and every title is made-up text of the same length.

| File | Operation | Source |
|---|---|---|
| `merge-requests.json` | MergeRequests | log: one review requested, `DRAFT_STATUS`; the reviewers' made-up names added by hand, since the old query asked none |
| `work-items.json` | WorkItems | log: 2 committed, 20 of 29 not committed; the old query asked no `type` and `state` |
| `work-items-variables.json` | WorkItems | log: the variables of `work-items.json` |
| `labels.json` | Labels | log: the check of a filter label |
| `related-merge-requests-none.json` | RelatedMergeRequests | log: a work item without related MRs |
| `merged-merge-requests.json` | MergedMergeRequests | log |
| `current-user-null.json` | CurrentUser | anonymous request: HTTP 200 without `currentUser` |
| `metadata-null.json` | Metadata | anonymous request: HTTP 200 without `metadata` |
| `invalid-token.json` | CurrentUser | request with a made-up token: HTTP 401 |
| `work-items-invalid-sort.json` | WorkItems | anonymous request with `sort: "NOPE"`; the list of values is shortened |

## Hand-written

The logs had no such answers.

| File | Why |
|---|---|
| `current-user.json` | CurrentUser with a username; same shape as `currentUser` in `merge-requests.json` |
| `metadata.json` | Metadata needs a token (`metadata-null.json`); the version is the one the related-MR spike saw |
| `insufficient-scope.json` | the OAuth error the old tool's test used for a token without `read_api`; GitLab's GraphQL controller answers `Invalid token` instead (see `docs/decisions.md`, lane G) |
| `merge-requests-sections.json` | authored and assigned at once, a review I approved, a review where I'm not among the reviewers, another project |
| `related-merge-requests.json` | an opened `[cascade]` MR, a merged one and a closed one, in the shape of the spike's query |
| `labels-search.json` | a search for "bug": `Triage` matches only by its description |
| `search-merge-requests.json` | the window's "In GitLab" search (WIN-07): a group scope with an open draft, a duplicate of an open one, a merged and a closed one without an author, a node without a number, and a project scope that is `null`; written from GitLab's GraphQL reference, never run against a real GitLab |
| `work-item-discussion.json` | a work item's comment threads: replies, system notes, a thread of system notes only, a time with fractions of a second; written from GitLab's GraphQL reference, never run against a real GitLab |
| `merge-request-details.json` | approval rules, a resolved and a not resolvable discussion, a diff note with replies and a system note, failed and running jobs; written from GitLab's GraphQL reference, never run against a real GitLab |
| `merge-request-details-basic.json` | the answer of a GitLab without approval rules: only `approvedBy`, no pipeline, more discussions than asked for |
| `merge-request-details-unknown-field.json` | the validation error of a GitLab that doesn't know a field of the full query: HTTP 200, errors and no data |
| `merge-request-reviews.json` | the reviewers with their interaction times, three diff versions and three commits: Sam reviewed before two pushes, Alex approved after the first one, Robin has not reviewed; written from GitLab's GraphQL reference, never run against a real GitLab |

## Written from the reference

| File | Operation | Source |
|---|---|---|
| `merge-request-closes-issues.json` | MergeRequestClosesIssues (REST `closes_issues`) | GitLab's REST reference, "List issues that close on merge": the fields the app reads, made-up values; not taken from a real server |
| `merge-request-related-issues.json` | MergeRequestRelatedIssues (REST `related_issues`) | the reference, "List issues related to the merge request"; one issue has `references.full` and one lives in another project |
