puts "VIVADO_VERSION=[version -short]"
foreach pattern {xcvu9p-flga2104-2L-e xcku115-flvb2104-2-e xczu9eg-ffvb1156-2-e xcu250* xcvu19p*fsvb3824*} {
  set parts [get_parts -quiet $pattern]
  puts "PATTERN=$pattern MATCHES=$parts"
  foreach part $parts {
    puts "PART=$part"
    foreach key {LUT_ELEMENTS FLIPFLOPS BLOCK_RAMS ULTRA_RAMS DSP AVAILABLE_IOBS GB_TRANSCEIVERS SLRS} {
      puts "$key=[get_property $key $part]"
    }
    # Resource counts identical across grades; one match suffices per pattern.
    break
  }
}
exit
