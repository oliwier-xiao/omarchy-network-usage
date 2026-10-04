# The bar widget's settings, checked as a whole: no duplicate key, the same keys in
# the schema and in the defaults, each default equal to its defaultValue and of the
# type the setting declares, an enum default among its options, an integer default
# whole and inside min..max. `jq -e -f tests/manifest-check.jq manifest.json`.
.barWidget as $w
| ($w.schema | map(.key)) as $sk
| ( ($sk | length) == ($sk | unique | length) )                                   # no duplicate keys
  and ( ($sk | sort) == ($w.defaults | keys | sort) )                               # same key set, both directions
  and ( $w.schema | all(. as $s | ($s | has("defaultValue")) and $s.defaultValue == $w.defaults[$s.key] and ($s.defaultValue | type) == ({"enum":"string","string":"string","boolean":"boolean","integer":"number"}[$s.type] // ($s.defaultValue | type)) ) )
  and ( $w.schema | all(. as $s | $s.type != "enum" or (($s.options // []) | index($s.defaultValue)) != null) )
  and ( $w.schema | all(. as $s | $s.type != "integer" or (($s.defaultValue | floor) == $s.defaultValue and $s.defaultValue >= $s.min and $s.defaultValue <= $s.max)) )
