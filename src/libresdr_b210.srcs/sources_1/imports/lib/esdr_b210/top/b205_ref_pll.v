//
// Copyright 2015 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module b205_ref_pll(
    input reset,
    input clk,      // 200 MHz sample clock
    input refclk,   // 40 MHz reference clock
    input ref,      // PPS or 10 MHz external reference
    input [15:0] dac_def,
    input force_fine,
    output [31:0] dac_now,
    output [31:0] phase_err_now,
    output reg lpps,
    output reg locked,
    output reg [4:0] dbg,

    // SPI lines to AD5662
    output sclk,
    output mosi,
    output sync_n
    );

    // Base parameters
    localparam SAMPLE_CLOCK_FREQ=200_000_000;
    localparam REF_FREQ_PPS=1;
    localparam REF_FREQ_10MHZ=10_000_000;
    localparam REF_CLK_FREQ=40_000_000;
    localparam PFD_FREQ_PPS=1;
    localparam PFD_FREQ_10MHZ=10;

    // Lock detection parameters
    localparam LOCK_TOLERANCE_PPM=1;
    localparam LOCK_MARGIN_PPS=(SAMPLE_CLOCK_FREQ/PFD_FREQ_PPS)*LOCK_TOLERANCE_PPM/1_000_000;
    localparam LOCK_MARGIN_10MHZ=(SAMPLE_CLOCK_FREQ/PFD_FREQ_10MHZ)*LOCK_TOLERANCE_PPM/1_000_000;

    // Reference frequency detection parameters
    // References are only valid if they are +/-5ppm because that is the range of the VCTXCO
    localparam REF_DETECT_PPM=20;
    localparam REF_PERIOD_PPS=SAMPLE_CLOCK_FREQ/REF_FREQ_PPS;
    localparam REF_PERIOD_10MHZ=SAMPLE_CLOCK_FREQ/REF_FREQ_10MHZ;
    localparam REF_PERIOD_PPS_MIN=REF_PERIOD_PPS-(REF_PERIOD_PPS*REF_DETECT_PPM/1_000_000)-1;
    localparam REF_PERIOD_PPS_MAX=REF_PERIOD_PPS+(REF_PERIOD_PPS*REF_DETECT_PPM/1_000_000)+1;
    localparam REF_PERIOD_10MHZ_MIN=REF_PERIOD_10MHZ-(REF_PERIOD_10MHZ*REF_DETECT_PPM/1_000_000)-1;
    localparam REF_PERIOD_10MHZ_MAX=REF_PERIOD_10MHZ+(REF_PERIOD_10MHZ*REF_DETECT_PPM/1_000_000)+1;

    // R divider parameters
    localparam RDIV_PPS=REF_FREQ_PPS/PFD_FREQ_PPS;
    localparam RDIV_10MHZ=REF_FREQ_10MHZ/PFD_FREQ_10MHZ;

    // N divider parameters (refclk is divided by 2)
    localparam NDIV_PPS=REF_CLK_FREQ/2/PFD_FREQ_PPS;
    localparam NDIV_10MHZ=REF_CLK_FREQ/2/PFD_FREQ_10MHZ;

    // PFD parameters
    localparam PFD_PERIOD_PPS=SAMPLE_CLOCK_FREQ/PFD_FREQ_PPS;
    localparam PFD_PERIOD_10MHZ=SAMPLE_CLOCK_FREQ/PFD_FREQ_10MHZ;
    
    
  /* Counter generating a local pps for the xo derived clock domains.
     nxt_lcnt is manipulated by a state machine (sstate) to allow
     quick re-alignment of the local pps rising edge with that of
     the reference.
  */
  reg [27:0] lcnt, nxt_lcnt;
  wire recycle = (28'd199_999_999==lcnt); // sets the period, 1 sec

  always @(posedge clk) begin
    lcnt <= nxt_lcnt;
    lpps <= lcnt > 28'd150_000_000; // ~25% duty cycle
  end
  



    // Initial divide by 2 for 40 MHz clock
    // (since refclk cannot be sampled directly)
    reg refclk_div;
    always @(posedge refclk) begin
        refclk_div <= ~refclk_div;
    end

    // flop signals into sample clock domain together
    // ASYNC_REG ensures Vivado places these flops in the same slice
    // for proper metastability settling (CDC from async/refclk to clk)
    (* ASYNC_REG = "TRUE" *) reg [3:0] refsmp;
    (* ASYNC_REG = "TRUE" *) reg [3:0] refclksmp;
    always @(posedge clk) begin
        refsmp <= {refsmp[2:0],ref};
        refclksmp <= {refclksmp[2:0],refclk_div};
    end

    // rising edge detection
    wire ref_rising = (refsmp[3:2] == 2'b01);
    wire refclk_rising = (refclksmp[3:2] == 2'b01);

    // reference frequency detection
    reg [27:0] refcnt;
    reg ref_detected;
    (* max_fanout = 50 *) reg ref_is_10M;
    reg ref_is_pps;
    wire valid_ref = ref_is_10M | ref_is_pps;
    always @(posedge clk) begin
        if (reset) begin
            refcnt <= 28'd0;
            ref_detected <= 1'b0;
            ref_is_10M <= 1'b0;
            ref_is_pps <= 1'b0;
        end
        else if (ref_rising) begin
            refcnt <= 28'd1;
            ref_detected <= 1'b1;
            ref_is_10M <= ((refcnt >= REF_PERIOD_10MHZ_MIN) && (refcnt <= REF_PERIOD_10MHZ_MAX));
            ref_is_pps <= ((refcnt >= REF_PERIOD_PPS_MIN) && (refcnt <= REF_PERIOD_PPS_MAX));
        end
        else if ((ref_is_10M && (refcnt > REF_PERIOD_10MHZ_MAX)) || (refcnt > REF_PERIOD_PPS_MAX)) begin
            // consider the reference lost
            refcnt <= 28'd0;
            ref_detected <= 1'b0;
            ref_is_10M <= 1'b0;
            ref_is_pps <= 1'b0;
        end
        else if (ref_detected)
            refcnt <= refcnt + 28'd1;
    end
    
    
  always @(*) begin//sync the generate pps to the input pps
    nxt_lcnt = recycle ? 26'd0 : lcnt + 1;
    if (ref_is_pps&ref_rising)
        nxt_lcnt = 0;
   end

    // R divider
    wire [23:0] rdiv = ref_is_10M ? RDIV_10MHZ : RDIV_PPS;
    reg [23:0] rcnt;
    wire [23:0] next_rcnt = ~valid_ref ? 24'd0 : (rcnt == rdiv) ? 24'd1 : rcnt + 1'b1;
    reg r_rising;
    always @(posedge clk) begin
        if (ref_rising)
            rcnt <= next_rcnt;
        r_rising <= (ref_rising && ((ref_is_10M && (rcnt == rdiv)) || ref_is_pps));
    end

    // N divider
    // Enable on rising edge of R after valid_ref
    // is asserted so R and N signals start aligned.
    // Disable if reference lost.
    wire [25:0] ndiv = ref_is_10M ? NDIV_10MHZ : NDIV_PPS;
    reg [25:0] ncnt;
    wire [25:0] next_ncnt = ~valid_ref ? 26'd0 : ncnt == ndiv ? 26'd1 : ncnt + 1'b1;
    reg n_rising;
    always @(posedge clk) begin
		if (refclk_rising)
			ncnt <= next_ncnt;
		n_rising <= (refclk_rising && (ncnt == ndiv));
    end

    // Frequency Counter
    wire signed [28:0] period = ref_is_10M ? PFD_PERIOD_10MHZ : PFD_PERIOD_PPS;
    reg signed [28:0] r_period_cnt;
    reg signed [28:0] freq_err;
    always @(posedge clk) begin
        if (reset | ~valid_ref) begin
            r_period_cnt <= 28'd0;
            freq_err <= 29'sd0;
        end
        else if (r_rising) begin
            r_period_cnt <= 28'd1;
            freq_err <= period - r_period_cnt;
        end
        else
            r_period_cnt <= r_period_cnt + 29'd1;
    end

    // Phase Counter
    reg signed [28:0] lead_cnt;
    reg lead_cnt_ena;
    reg signed [28:0] lead;

    always @(posedge clk) begin
        // Count how much N leads R
        // The count is negative because it measures
        // how much the VCTCXO must be slowed down.
        if (~valid_ref | n_rising) begin
            lead_cnt <= 29'sd0;
            lead_cnt_ena <= 1'b1;
            if (r_rising)
                lead <= 29'sd0;
        end
        else if (r_rising) begin
            if (lead_cnt_ena)
                lead <= lead_cnt - 29'sd1;
            else begin
                // R rising with no preceding N rising.
                // N has changed from leading to lagging R,
                // but we don't yet know by how much so
                // assume 1.
                lead <= 29'sd1;
            end
            lead_cnt_ena <= 1'b0;
        end
        else if (lead_cnt_ena)
            lead_cnt <= lead_cnt - 29'sd1;
    end

    // PFD State Machine
    localparam MEASURE                  =10'b00_0000_0001;
    localparam CAPTURE                  =10'b00_0000_0010;
    localparam CAPTURE_LAG              =10'b00_0000_0100;
    localparam CAPTURE_LEAD             =10'b00_0000_1000;
    localparam CALCULATE_ERROR          =10'b00_0001_0000;
    localparam CALCULATE_10M_GAIN       =10'b00_0010_0000;
    localparam CALCULATE_ADJUSTMENT0    =10'b00_0100_0000;
    localparam CALCULATE_ADJUSTMENT1    =10'b00_1000_0000;
    localparam CALCULATE_OUTPUT_VALUE   =10'b01_0000_0000;
    localparam APPLY_OUTPUT_VALUE       =10'b10_0000_0000;
    localparam ERR_BITS                 = 29;
    localparam LOCK_REACHED             =9'd100;
    localparam DAC_IN_BITS              =16;
    localparam DAC_RES_BITS             =12;
    localparam SUM_EXTRA_BITS           =6;
    localparam DAC_EXTRA_BITS           =2;
    localparam ACC_BITS                 = ERR_BITS+SUM_EXTRA_BITS;
    localparam DAC_REM_BITS             =DAC_IN_BITS-DAC_RES_BITS+DAC_EXTRA_BITS;
    localparam PRESET_CNT_BITS          =7;
    
    reg [9:0] state;
    wire signed [ERR_BITS-1:0] lock_margin = ref_is_10M ? LOCK_MARGIN_10MHZ : LOCK_MARGIN_PPS;
    wire signed [ERR_BITS-1:0] lock_margin2x = ref_is_10M ? (LOCK_MARGIN_10MHZ<<<1) : (LOCK_MARGIN_PPS<<<1);
    wire signed [ERR_BITS-1:0] lag = lead + period;
    reg signed [ERR_BITS-1:0] phase_err;
    reg signed [ERR_BITS-1:0] phase_err_shifted;
    reg signed [ACC_BITS-1:0] freq_err_shifted;
    reg signed [ERR_BITS-1:0] err;
    reg signed [ERR_BITS-1:0] shift;
    reg signed [ACC_BITS-1:0] adj;
    reg signed [ACC_BITS-1:0] adj_no_lock_10M;
    reg signed [ACC_BITS-1:0] adj_lock_10M;
    reg signed [ACC_BITS-1:0] adj_1pps;
    reg signed [ACC_BITS-1:0] adj_buff;
    reg signed [ACC_BITS-1:0] sum = 32767 << SUM_EXTRA_BITS;
    reg scale_down = 0;
    wire [DAC_IN_BITS-1:0] daco = sum[DAC_IN_BITS+SUM_EXTRA_BITS-1:SUM_EXTRA_BITS];
    wire [DAC_REM_BITS-1:0] dac_rem = sum[DAC_REM_BITS+SUM_EXTRA_BITS-DAC_EXTRA_BITS-1:SUM_EXTRA_BITS-DAC_EXTRA_BITS];
    reg [8:0] lock_counter;
    reg ld;
    reg ld2x;
    always @(posedge clk) begin
        if (reset || ~valid_ref) begin
            state <= MEASURE;
            sum <= dac_def<<<SUM_EXTRA_BITS;
            err <= 'sd0;
            freq_err_shifted <= 'sd0;
            phase_err_shifted <= 'sd0;
            shift <= 'sd0;
            adj <= 'sd0;
            adj_no_lock_10M <= 'sd0;
            adj_lock_10M <= 'sd0;
            adj_1pps <= 'sd0;
            adj_buff <= 'sd0;
            lock_counter <= 'd0;
            scale_down <= 0;
            ld <= 'd0;
            ld2x <= 'd0;
        end
        else begin
            case(state)
                MEASURE: begin
                    if (r_rising)
                        state <= CAPTURE;
                end
                CAPTURE: begin
                    if (lag < -lead)
                        state <= CAPTURE_LAG;
                    else 
                        state <= CAPTURE_LEAD;
                end
                CAPTURE_LAG: begin
                    phase_err <= lag;
                    ld <= (lag <= lock_margin);
                    ld2x <= (lag > lock_margin2x);
                    state <= CALCULATE_ERROR;
                end
                CAPTURE_LEAD: begin
                    phase_err <= lead;
                    ld <= (-lead <= lock_margin);
                    ld2x <= (lead < -lock_margin2x);
                    state <= CALCULATE_ERROR;
                end
                CALCULATE_ERROR: begin
                    err <= phase_err + freq_err;
                    adj_buff <= (err <<< 4);
                    state <= ref_is_10M ? CALCULATE_10M_GAIN : CALCULATE_ADJUSTMENT0;
                end
                CALCULATE_10M_GAIN: begin
                    shift <= (err < -7 || err > 7) ? 7 : (err < 0 ? -err : err);
                    lock_counter <= (ld == 1'b1) ? ((lock_counter != LOCK_REACHED) ? lock_counter + 1 : lock_counter) : ((lock_counter != 0) ? lock_counter - 1 : 0);
                    freq_err_shifted <= freq_err<<< SUM_EXTRA_BITS;
                    phase_err_shifted <= phase_err<<<1;
                    if(freq_err != 'sd0)
                        scale_down <= freq_err[ERR_BITS-1]^phase_err[ERR_BITS-1];
                    state <= CALCULATE_ADJUSTMENT0;
                end
                CALCULATE_ADJUSTMENT0: begin
                    // The VCTCXO is +/-5 ppm from 0.3V to 1.5V and the DAC is 16 bits,
                    // which works out to 0.000228885 ppm per DAC unit.
                    // The 200 MHz sampling clock means each unit of error is 0.005 ppm,
                    // which works out to 21.845 DAC units to correct each unit of error.
                    // Theory is nice, but the proportional and integral gains used here
                    // were determined through manual tuning.

                    // Switch to narrow band tracking after locking
                    adj_no_lock_10M <= err <<< (shift + SUM_EXTRA_BITS);
                    adj_lock_10M <= scale_down?((freq_err_shifted + phase_err_shifted)>>>1):(freq_err_shifted + phase_err_shifted);
                    adj_1pps <=  (adj_buff - err) <<< SUM_EXTRA_BITS; //adj <=  (err <<< 4) - err;
                    if(ld2x) // Instant loss of lock
                        lock_counter <= 0;

                    state <= CALCULATE_ADJUSTMENT1;
                end
                CALCULATE_ADJUSTMENT1: begin
                    if (ref_is_10M)
                        adj <= (lock_counter == LOCK_REACHED ) ? adj_lock_10M : adj_no_lock_10M;
                    else
                        adj <=  adj_1pps;
                    state <= CALCULATE_OUTPUT_VALUE;
                end
                CALCULATE_OUTPUT_VALUE: begin
                    sum <= sum + adj;
                    state <= APPLY_OUTPUT_VALUE;
                end
                APPLY_OUTPUT_VALUE: begin
                    // Clip and apply
                    if (sum < 0) begin
                        sum <= 0;
                    end else if (sum > (65535 <<< SUM_EXTRA_BITS)) begin
                        sum <= (65535 <<< SUM_EXTRA_BITS);
                    end
                    state <= MEASURE;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (~locked & (lock_counter == LOCK_REACHED))
            locked <= 1'b1;
        else if (locked & (lock_counter == 0))
            locked <= 1'b0;
    end

    //assign dac_now = {sum[30],sum};
    assign dac_now = {freq_err[28],freq_err[28],freq_err[28],freq_err};
    assign phase_err_now = {phase_err[28],phase_err[28],phase_err[28],phase_err};
    wire ready_out;
    reg [DAC_REM_BITS-1:0] dac_rem_comp;
    reg [DAC_IN_BITS-1:0] dac_out;
    reg [DAC_IN_BITS-1:0] dac_out_prev;
    reg ready_prev;
    wire dac_needs_sync = (daco & 16'hfff0) != (dac_out_prev & 16'hfff0); 

    wire ds_vo;
    delta_sigma_dac #(.NBITS(DAC_REM_BITS)) res_extender(
        .clk(clk),
        .en((ready_out ^ ready_prev) && ready_out),
        .rst(reset || (~valid_ref && ~force_fine)),
        .sync(dac_needs_sync),
        .dat(dac_rem_comp),
        .d(ds_vo)
    );

    always @(posedge clk) begin
        dac_rem_comp<= force_fine?(daco[DAC_IN_BITS-DAC_RES_BITS-1:0]<< DAC_EXTRA_BITS):dac_rem;
        dbg[1] <= phase_err>0;
        dbg[2] <= phase_err<0;
        dbg[3] <= freq_err>0;
        dbg[4] <= freq_err<0;
    end
    always @(posedge clk) if(reset || (~valid_ref && ~force_fine)) begin
        dac_out <= daco;
        ready_prev <= 1'b0;
    end else begin
        if((ready_out ^ ready_prev) && ready_out) begin
            if(ds_vo)
                dac_out <= (daco & 16'hfff0)+16'h10;
            else
                dac_out <= (daco & 16'hfff0);
        end
        ready_prev <= ready_out;
        if(dac_needs_sync) dbg[0] <= ~dbg[0];
        dac_out_prev <= daco;
    end

    DACx311_auto_spi dac
    (
        .en(valid_ref || force_fine),
        .clk(clk),
        .dat(dac_out),
        .sclk(sclk),
        .mosi(mosi),
        .sync_n(sync_n),
        .ready_out(ready_out)
    );
endmodule
