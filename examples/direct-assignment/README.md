# Direct (One-Off) Assignment Example

`direct_assignments` granting specific named users a package
directly, for one-offs the `auto_assignment_policy` OData filter can't express.

The auto-assignment policy covers the dept-wide population; `direct_assignments`
covers the exceptions (a cross-department contractor, a temporary backfill, a
single exception). Each user principal name is resolved to an object ID and
submitted as a Microsoft Graph **AdminAdd** request through the package's
request-based policy admin-initiated, so no request or approval is needed.
