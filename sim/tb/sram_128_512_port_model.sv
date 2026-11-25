// Functional simulation view only. Do not put this in synthesis filelists.
// Single 1RW port, registered read; no R/W on the same edge, inactive hold.
module sram_128_512(output logic [127:0] Q,input wire CLK,CEN,GWEN,
  input wire [127:0] WEN,D,input wire [8:0] A,input wire [2:0] EMA,
  input wire [1:0] EMAW,input wire EMAS,RET1N);
  logic [127:0] mem[512];
  always @(posedge CLK)if(!CEN)begin
    if($isunknown({GWEN,A}) || RET1N!==1'b1)$fatal(1,"invalid active SRAM controls");
    if(GWEN)Q<=mem[A];
    else begin Q<='x;for(integer k=0;k<128;k++)if(!WEN[k])mem[A][k]<=D[k];end
  end
endmodule
