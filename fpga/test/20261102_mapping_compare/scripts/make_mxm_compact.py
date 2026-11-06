"""Replace 26 serial conditional one-bit normalization steps with exact LZC/shift."""
from run import EXP,REPO

def main():
    pkg=(REPO/'rtl/vxm/lpu_vxm_math_pkg.sv').read_text()
    start=pkg.index('function automatic logic [31:0] fp32_add_rne_ordered(')
    end=pkg.index('endfunction',start)+len('endfunction')
    fn=pkg[start:end]
    fn=fn.replace('  integer distance;','  integer distance;\n  integer leading_zeroes, shift_limit;\n  logic leading_found;')
    old="""          for (integer normalize_step = 0;
               normalize_step < 26; normalize_step++)
            if (!normalized[26] && (exponent > 1)) begin
              normalized = normalized << 1;
              exponent = exponent - 1;
            end"""
    new="""          // Exactly the same bounded shift as the original 26 iterations:
          // min(leading_zeroes(normalized), max(exponent-1,0), 26).
          leading_zeroes = 26;
          leading_found = 1'b0;
          for (integer n = 0; n < 27; n++) begin
            if (!leading_found && normalized[26-n]) begin
              leading_zeroes = n;
              leading_found = 1'b1;
            end
          end
          shift_limit = exponent > 1 ? exponent-1 : 0;
          if (leading_zeroes > shift_limit)
            leading_zeroes = shift_limit;
          normalized = normalized << leading_zeroes;
          exponent = exponent - leading_zeroes;"""
    assert fn.count(old)==1
    fn=fn.replace(old,new)
    (EXP/'rtl/math_mxm_compact_pkg.sv').write_text(pkg[:start]+fn+pkg[end:])
    print('Generated exact bounded-LZC normalization; add order and rounding unchanged.')

if __name__=='__main__':main()
