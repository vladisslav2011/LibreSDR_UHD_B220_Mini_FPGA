`timescale 1ns / 100ps

module delta_sigma_dac

#(
    parameter NBITS = 4
)
(
    input wire clk,
    input wire rst,
    input wire en,
    input wire sync,
    input wire [NBITS-1:0] dat,
    output reg d
    
);

localparam ds_bw = NBITS;
localparam ds_max = (1<<NBITS);
localparam ds_min = 0;
wire [NBITS*2:0] ds_tgt = dat<<NBITS;
reg [NBITS*2:0] ds_acc = 0;
reg [NBITS*2:0] ds_inc=0;
reg [NBITS*2:0] ds_dec=0;
reg ds_upd=0;


always @(posedge clk)
begin
    if(rst)
    begin
        d<=1'b0;
        ds_acc<=0;
        ds_upd <= 0;
        ds_inc<=0;
        ds_dec<=0;
   end if(sync)
        ds_acc <= ds_tgt;
   else begin
        if(en) begin
            if(d) begin
                ds_acc<= ds_acc+ds_inc;
                if(ds_acc+ds_inc>ds_tgt)
                    d<=1'b0;
                
            end else begin
                ds_acc<= ds_acc-ds_dec;
                if(ds_acc-ds_dec<ds_tgt)
                    d<=1'b1;

            end
            if(~ds_upd)
                ds_upd <= 1'b1;
        end
        if(ds_upd)
        begin
            ds_inc<=((ds_max<<ds_bw)-ds_acc)>>ds_bw;
            ds_dec<=(ds_acc-(ds_min<<ds_bw))>>ds_bw;
            ds_upd <= 1'b0;
        end 
    end
end

endmodule

