puts "VIVADO_VERSION=[version -short]"
foreach pattern {xcvu9p*flga2104* xczu9eg*ffvb1156* xcku115*flva1517* xcvu37p*fsvh2892*} {
  foreach part [get_parts -quiet $pattern] {
    puts "CANDIDATE_PART=$part"
    report_property $part
  }
}
exit
