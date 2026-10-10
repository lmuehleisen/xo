# shellcheck shell=bash
# Shared crew-dispatch lane schema: model classes, their provider routes, data
# policies, and the lane rules that list classes.
# Usage: . bin/fm-dispatch-lanes-lib.sh
#
# docs/configuration.md "Crew dispatch profiles" owns the field semantics; this
# file is the single owner of the structural checks that bin/fm-bootstrap.sh
# and bin/fm-dispatch-resolve.sh both apply, so the two never drift.
#
# FM_DISPATCH_LANES_JQ is jq program text to prepend to a consumer program:
#   dispatch_lanes_error      on the config object: the first structural lane,
#                             class, or data-policy error as a string, or empty.
#   dispatch_class_routes     on the config object: every class route profile,
#                             so a consumer's own harness, effort, provider, and
#                             floor checks cover class routes too.
#   dispatch_lane_refs($rule) the rule's class references as {class, gate} objects.
# Per-route harness verification and effort support stay with each consumer,
# which already owns them for `use` and `default` profiles.
#
# fm_dispatch_model_family <rules-file> <harness> <model>
#   Prints the one model family every class routing <harness> with <model>
#   declares (an empty model matches a route with no model), or nothing when no
#   class routes it or the file is unreadable or malformed. bin/fm-spawn.sh
#   records it as model_family= so a later second opinion can exclude it.

# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_DISPATCH_LANES_JQ='
  def dl_name: type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*\\z");
  def dl_classes: (.classes // {}) | if type == "object" then . else {} end;
  def dispatch_lane_refs($rule):
    [($rule.classes // [])[] | if type == "string" then {class: .} else . end];
  def dispatch_class_routes:
    [dl_classes[] | objects | (.routes // []) | arrays | .[]];
  def dl_route_key: [.harness, (.model // null), (.effort // null)] | @json;
  def dl_route_bad:
    type != "object"
    or ((.harness | type) != "string") or ((.harness | length) == 0)
    or (has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or (has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or (has("provider") and (.provider | dl_name | not))
    or (has("floor") and (
      (.floor | type) != "object"
      or ((.floor.scope | type) != "string") or ((.floor.scope | length) == 0)
      or ((.floor.min_percent | type) != "number") or (.floor.min_percent < 0) or (.floor.min_percent > 100)
      or (.floor | has("provider"))));
  def dl_policy_tags($p): (($p.allow_tags // []) + ($p.deny_tags // []));
  def dispatch_lanes_error:
    dl_classes as $classes |
    (.live_cap_groups // {}) as $groups |
    (.data_policies // {}) as $policies |
    ([(.rules // [])[]? | objects | select(has("classes"))]) as $lanes |
    if has("classes") and (.classes | type) != "object" then "classes must be an object of named model classes"
    elif any($classes | keys[]; dl_name | not) then "class names must match ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif any($classes[]; type != "object") then "each class must be an object"
    elif any($classes[]; (keys - ["family", "routes", "experiment", "data_policy", "unmetered", "spend_priority", "max_live", "live_cap_group", "why"]) | length > 0) then
      "unknown class field: " + ([$classes[] | keys - ["family", "routes", "experiment", "data_policy", "unmetered", "spend_priority", "max_live", "live_cap_group", "why"] | .[]] | unique | join(", "))
    elif any($classes[]; has("max_live") and (
        (.max_live | type) != "number" or .max_live <= 0
        or (.max_live | isinfinite) or .max_live != (.max_live | floor))) then
      "class max_live must be a positive integer"
    elif has("live_cap_groups") and (.live_cap_groups | type) != "object" then "live_cap_groups must be an object of named cap groups"
    elif any($groups | keys[]; dl_name | not) then "live cap group names must match ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif any($groups[]; type != "object") then "each live cap group must be an object"
    elif any($groups[]; (keys - ["max_live"]) | length > 0) then
      "unknown live cap group field: " + ([$groups[] | keys - ["max_live"] | .[]] | unique | join(", "))
    elif any($groups[];
        (.max_live | type) != "number" or .max_live <= 0
        or (.max_live | isinfinite) or .max_live != (.max_live | floor)) then
      "live cap group max_live must be a positive integer"
    elif any($classes[]; has("live_cap_group") and (
        (.live_cap_group | dl_name | not) or ($groups[.live_cap_group] == null))) then
      "class live_cap_group must name a declared live cap group"
    elif any($classes[]; has("unmetered") and (.unmetered | type) != "boolean") then
      "class unmetered must be a boolean"
    elif any($classes[]; has("spend_priority") and .unmetered != true) then
      "class spend_priority requires unmetered: true"
    elif any($classes[]; has("spend_priority") and (
        (.spend_priority | type) != "number" or (.spend_priority | isinfinite) or (.spend_priority | isnan))) then
      "class spend_priority must be a finite number"
    elif any($classes[]; .family | dl_name | not) then "each class needs family matching ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif any($classes[]; (.routes | type) != "array" or (.routes | length) == 0) then "each class needs a non-empty routes array"
    elif any($classes[] | .routes[]; dl_route_bad) then
      "each class route needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*$ when present"
    elif any($classes[] | .routes[]; has("unmetered")) then "unmetered belongs on the class, not on a route"
    elif any($classes[] | .routes[]; has("spend_priority")) then "spend_priority belongs on the class, not on a route"
    elif any($classes[]; .unmetered == true and any(.routes[]; has("floor"))) then
      "an unmetered class route must not have a quota floor"
    elif any($classes[]; (.routes | map(dl_route_key)) as $k | ($k | length) != ($k | unique | length)) then
      "each class must not contain duplicate harness, model, and effort routes"
    elif any($classes[]; has("experiment") and (
        (.experiment | type) != "object" or ((.experiment | keys) - ["share", "why"] | length) > 0
        or (.experiment.share | type) != "number" or .experiment.share <= 0 or .experiment.share > 1)) then
      "class experiment needs share greater than 0 and at most 1"
    elif any($classes[]; has("why") and (.why | type) != "string") then "class why must be a string"
    elif has("data_policies") and (.data_policies | type) != "object" then "data_policies must be an object of named policies"
    elif any($policies | keys[]; dl_name | not) then "data policy names must match ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif any($policies[]; type != "object") then "each data policy must be an object"
    elif any($policies[]; (keys - ["allow_projects", "allow_tags", "deny_tags", "why"]) | length > 0) then
      "unknown data policy field: " + ([$policies[] | keys - ["allow_projects", "allow_tags", "deny_tags", "why"] | .[]] | unique | join(", "))
    elif any($policies[]; has("allow_projects") and (
        (.allow_projects | type) != "array" or any(.allow_projects[]; (type != "string") or length == 0))) then
      "data policy allow_projects must be an array of project names"
    elif any($policies[]; any(("allow_tags", "deny_tags") as $f | .[$f]; . != null and (type != "array" or any(.[]; dl_name | not)))) then
      "data policy allow_tags and deny_tags must be arrays of tags matching ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif any($policies[]; dl_policy_tags(.) | length != (unique | length)) then "a data policy tag must appear only once across allow_tags and deny_tags"
    elif any($policies[]; has("why") and (.why | type) != "string") then "data policy why must be a string"
    elif any($classes[]; has("data_policy") and (((.data_policy | type) != "string") or ($policies[.data_policy] == null))) then
      "class data_policy must name a declared data policy"
    elif any((.rules // [])[]? | objects; has("classes") and has("use")) then "a rule takes either use or classes, not both"
    elif any((.rules // [])[]? | objects; (has("lane") or has("order")) and (has("classes") | not)) then "lane and order apply only to a rule with classes"
    elif any($lanes[]; (.classes | type) != "array" or (.classes | length) == 0) then "each lane rule needs a non-empty classes array"
    elif any($lanes[]; .lane | dl_name | not) then "each lane rule needs lane matching ^[a-z0-9]+(-[a-z0-9]+)*$"
    elif ([$lanes[].lane] | length) != ([$lanes[].lane] | unique | length) then "lane names must be unique"
    elif any($lanes[]; has("order") and (.order != "ordered" and .order != "pool")) then "lane order must be ordered or pool"
    elif any($lanes[]; has("select")) then "select applies only to use profiles, not lane classes"
    elif any($lanes[] | .classes[]; (type == "string" and dl_name) or (type == "object" and (.class | dl_name) and ((keys - ["class", "gate"]) | length) == 0) | not) then
      "each lane class must be a class name or an object with class and optional gate"
    elif any(dispatch_lane_refs($lanes[])[]; .class as $c | ($classes | has($c)) | not) then
      "lane names an undeclared class: " + ([dispatch_lane_refs($lanes[])[] | .class as $c | select(($classes | has($c)) | not) | $c] | unique | join(", "))
    elif any($lanes[]; [dispatch_lane_refs(.)[].class] | length != (unique | length)) then "a lane must not list a class twice"
    elif any(dispatch_lane_refs($lanes[])[]; has("gate") and .gate != "others-ahead-of-pace") then
      "unknown gate: " + ([dispatch_lane_refs($lanes[])[] | select(has("gate") and .gate != "others-ahead-of-pace") | .gate | tostring] | unique | join(", "))
    elif any($lanes[]; (.order // "pool") == "ordered" and any(dispatch_lane_refs(.)[]; has("gate"))) then "a gate applies only in a pool lane"
    elif any($lanes[]; . as $lane | [dispatch_lane_refs($lane)[] | $classes[.class].routes[] | dl_route_key] | length != (unique | length)) then
      "a lane must not reach the same harness, model, and effort through two classes"
    elif ([$classes[] | .family as $f | .routes[] | {k: ([.harness, (.model // null)] | @json), f: $f}]
          | group_by(.k) | any(.[]; (map(.f) | unique | length) > 1)) then
      "a harness and model routed by more than one class must keep one family"
    else empty end;
'

fm_dispatch_model_family() {
  local file=$1 harness=$2 model=${3:-}
  [ -f "$file" ] && [ -r "$file" ] || return 0
  jq -r --arg h "$harness" --arg m "$model" '
    [(.classes // {}) | objects | .[] | objects
      | select(any((.routes // []) | arrays | .[]; type == "object" and .harness == $h and (.model // "") == $m))
      | .family | strings]
    | unique | if length == 1 then .[0] else empty end
  ' "$file" 2>/dev/null || true
}
