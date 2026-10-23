# Summary of `terraform show -json` output: counts, a warning on deletes, one row per resource.
[(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
| ($c | map(select(.change.actions == ["create"])) | length) as $add
| ($c | map(select(.change.actions == ["update"])) | length) as $chg
| ($c | map(select(.change.actions == ["delete"])) | length) as $del
| ($c | map(select(.change.actions | length == 2)) | length) as $rep
| "### Terraform plan: \($add) to add, \($chg) to change, \($rep) to replace, \($del) to destroy",
"",
(if ($del + $rep) > 0 then "> **Warning: this change deletes or replaces \($del + $rep) resource(s).** Check each one below.\n" else empty end),
(if ($c | length) == 0 then "No changes: AWS stays as it is." else
"| Action | Resource |", "| --- | --- |",
($c[] | "| \(.change.actions | if . == ["create"] then "create" elif . == ["update"] then "update in place" elif . == ["delete"] then "**destroy**" else "**replace**" end) | `\(.address)` |")
end)
