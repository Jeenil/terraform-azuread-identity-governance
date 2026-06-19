# Auto-Assignment Lifecycle Example

Demonstrates the full set of `auto_assignment_policy` controls and how they
converge as desired state.

Auto-assignment policies are managed as a native `msgraph_resource`. Changing the
`filter` (or the structured fields that build it), `remove_when_target_leaves`, or
`grace_period_before_removal` updates the live policy **in place** (PUT) on the
next apply — the change is visible at `plan` time and there is no duplicate-policy
risk on re-apply.

Shows:

- Member + Owner package pair off one department, split by job title
- `remove_when_target_leaves` + a non-default `grace_period_before_removal`
  (`P14D` / `P30D`)
- `hidden = true` — auto-assigned packages are never requested, so hide them from
  the My Access request portal

For a single raw OData expression instead of structured fields, see
[`../raw-filter`](../raw-filter).
