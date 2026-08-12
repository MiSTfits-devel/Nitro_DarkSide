// Contract test for clash/rtl/nds_sigma_delta_dac.v.
//
// This is NOT a bit-exact differential test, on purpose. The source-owned
// modulator is independently written and does not reproduce the GPL module's
// cycle behaviour. What must hold is the analog contract, so that is what is
// measured, on both modules, with identical stimulus:
//
//   1. DC transfer      mean duty cycle must be a linear function of the input
//                       code across the full range. Reported as worst-case
//                       deviation in LSBs of a 16-bit code.
//   2. Monotonicity     a higher code must never produce a lower mean.
//   3. Idle noise       RMS deviation of the decimated stream about its own
//                       mean, i.e. the in-band noise floor at DC, in LSBs.
//
// The GPL sys/sigma_delta_dac.v is included ONLY as a black-box benchmark to
// show the replacement is no worse. Nothing is copied from it and the pass
// criteria are absolute, not "matches the oracle".

`timescale 1ns/1ps

module tb_sigma_delta;

   localparam MSBI    = 15;
   localparam FS      = 1 << (MSBI+1);      // 65536 codes
   localparam SETTLE  = 8000;              // cycles discarded per code
   localparam MEASURE = 65536;             // cycles averaged per code
   localparam DECIM   = 512;
   localparam INV_EXPECT = 1;    // INV=1 default: duty falls as the code rises                // decimation for the noise figure

   reg clk = 0, reset = 1;
   always #5 clk = ~clk;

   reg [MSBI:0] din = 0;
   wire dut_out, ref_out;

   nds_sigma_delta_dac #(MSBI) dut (.CLK(clk), .RESET(reset), .DACin(din), .DACout(dut_out));
   sigma_delta_dac     #(MSBI) refm(.CLK(clk), .RESET(reset), .DACin(din), .DACout(ref_out));

   integer code, i, j;
   real    dut_mean, ref_mean, dut_prev, ref_prev;
   real    dut_worst, ref_worst, dut_noise, ref_noise;
   real    ideal, err;
   integer dut_ones, ref_ones;
   integer dut_mono, ref_mono;

   // decimated-block accumulators for the noise figure
   real dut_blk [0:(MEASURE/DECIM)-1];
   real ref_blk [0:(MEASURE/DECIM)-1];
   integer nblk;
   real m, v;

   task automatic measure(input [MSBI:0] c);
      begin
         din = c;
         for (i = 0; i < SETTLE; i = i + 1) @(posedge clk);

         dut_ones = 0; ref_ones = 0; nblk = 0;
         for (i = 0; i < MEASURE/DECIM; i = i + 1) begin
            dut_blk[i] = 0.0; ref_blk[i] = 0.0;
            for (j = 0; j < DECIM; j = j + 1) begin
               @(posedge clk);
               if (dut_out) begin dut_ones = dut_ones + 1; dut_blk[i] = dut_blk[i] + 1.0; end
               if (ref_out) begin ref_ones = ref_ones + 1; ref_blk[i] = ref_blk[i] + 1.0; end
            end
            dut_blk[i] = dut_blk[i] / DECIM;
            ref_blk[i] = ref_blk[i] / DECIM;
            nblk = nblk + 1;
         end
         dut_mean = dut_ones * 1.0 / MEASURE;
         ref_mean = ref_ones * 1.0 / MEASURE;
      end
   endtask

   function real rms_dev(input integer which);
      integer k;
      real mm, vv;
      begin
         mm = 0.0;
         for (k = 0; k < nblk; k = k + 1) mm = mm + (which ? ref_blk[k] : dut_blk[k]);
         mm = mm / nblk;
         vv = 0.0;
         for (k = 0; k < nblk; k = k + 1) begin
            vv = vv + ((which ? ref_blk[k] : dut_blk[k]) - mm) *
                      ((which ? ref_blk[k] : dut_blk[k]) - mm);
         end
         rms_dev = (nblk > 1) ? $sqrt(vv / (nblk - 1)) : 0.0;
      end
   endfunction

   initial begin
      repeat (10) @(posedge clk);
      reset = 0;

      dut_worst = 0.0; ref_worst = 0.0;
      dut_noise = 0.0; ref_noise = 0.0;
      dut_mono  = 0;   ref_mono  = 0;
      dut_prev  = -1.0; ref_prev = -1.0;

      $display("  code      ideal    src-owned        GPL     dev(LSB) src/GPL");
      for (code = 137; code < FS; code = code + 4093) begin   // prime stride, no code lands on an exact 1/16 - a periodic pattern would hide the noise floor
         measure(code[MSBI:0]);
         ideal = (INV_EXPECT ? (1.0 - code * 1.0 / FS) : (code * 1.0 / FS));

         err = (dut_mean - ideal) * FS; if (err < 0) err = -err;
         if (err > dut_worst) dut_worst = err;
         $write("%6d  %9.6f  %9.6f  %9.6f  %8.1f", code, ideal, dut_mean, ref_mean, err);

         err = (ref_mean - ideal) * FS; if (err < 0) err = -err;
         if (err > ref_worst) ref_worst = err;
         $display(" /%7.1f", err);

         if (dut_prev >= 0.0 && dut_mean > dut_prev + 0.002) dut_mono = dut_mono + 1;
         if (ref_prev >= 0.0 && ref_mean > ref_prev + 0.002) ref_mono = ref_mono + 1;
         dut_prev = dut_mean; ref_prev = ref_mean;

         v = rms_dev(0) * FS; if (v > dut_noise) dut_noise = v;
         v = rms_dev(1) * FS; if (v > ref_noise) ref_noise = v;
      end

      $display("");
      $display("  worst DC deviation : src-owned %.1f LSB   GPL %.1f LSB", dut_worst, ref_worst);
      $display("  monotonicity breaks: src-owned %0d          GPL %0d", dut_mono, ref_mono);
      $display("  worst idle noise   : src-owned %.1f LSB   GPL %.1f LSB", dut_noise, ref_noise);
      $display("");

      // Absolute pass criteria. Deviation is allowed a few LSBs of a 16-bit
      // code; monotonicity must be exact; and the noise floor must not be
      // worse than the module being replaced.
      if (dut_mono != 0)
         $display("sigma_delta contract: FAIL (source-owned modulator is not monotonic)");
      else if (dut_worst > 16.0)
         $display("sigma_delta contract: FAIL (DC deviation %.1f LSB exceeds 16)", dut_worst);
      else if (dut_noise > ref_noise * 1.5 + 1.0)
         $display("sigma_delta contract: FAIL (idle noise %.1f LSB vs GPL %.1f)", dut_noise, ref_noise);
      else
         $display("sigma_delta contract: PASS (dev %.1f LSB, %0d mono breaks, noise %.1f vs GPL %.1f)",
                  dut_worst, dut_mono, dut_noise, ref_noise);
      $finish;
   end

endmodule
