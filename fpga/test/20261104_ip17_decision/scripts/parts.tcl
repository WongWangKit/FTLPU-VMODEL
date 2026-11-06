puts "VIVADO_VERSION=[version -short]"
foreach pattern {xcvu19p-fsvb3824-2-e xcvu440-flgb2377-2-e xcv80*} {
    set parts [get_parts -quiet $pattern]
    puts "PATTERN=$pattern MATCH_COUNT=[llength $parts]"
    foreach part $parts {
        puts "PART=$part"
        foreach key {LUT_ELEMENTS FLIPFLOPS BLOCK_RAMS ULTRA_RAMS DSP SLRS} {
            puts "$key=[get_property -quiet $key $part]"
        }
        break
    }
}
puts "PART_AUDIT_COMPLETE"
exit
