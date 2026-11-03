# Inbox fixtures

Answers of GitLab's GraphQL API for the Inbox (GitLab's To-Do List, `Tests/MenubarCoreTests/Inbox/`). All
hand-written from GitLab's schema source and docs: no real answer was taken yet, so the field names are inferred
until the first run against a real GitLab. Host `gitlab.example.com`, made-up projects and people.

| File | Operation | Why |
|---|---|---|
| `todos.json` | InboxTodos | six pending to-dos (mention, review request, assignment, failed pipeline, an action the app doesn't know with a deleted target, a direct address without an author) and one snoozed |
| `todos-no-snooze.json` | InboxTodos | a GitLab before 17.4 refusing `isSnoozed` (the message's shape follows graphql-ruby) |
| `snooze-unknown.json` | TodoSnooze | a GitLab without the snooze mutation |
| `todo-mark-done.json` | TodoMarkDone | GitLab took it |
| `todo-mark-done-refused.json` | TodoMarkDone | GitLab refused it in the payload's `errors` |
