//
// Copyright 2011-2012 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//



// 64 bits worth of ticks
//
// Not concerned with clock wrapping, human race will likely have extermintated it's self by this time.
//

module time_compare
  (
   input [63:0] time_now,
   input [63:0] trigger_time,
   output now,
   output early,
   output late,
   output too_early);

    assign now = time_now == trigger_time;
    assign late = time_now > trigger_time;
    assign early = ~now & ~late;
    assign too_early = 0; //not implemented

endmodule // time_compare
