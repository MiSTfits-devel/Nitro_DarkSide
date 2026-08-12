// SPDX-License-Identifier: LicenseRef-repo-LICENSE
// Source-owned sigma-delta DAC: 1-bit output feeding the analog low-pass on
// the MiSTer I/O board. Drop-in for the GPL sys/sigma_delta_dac.v.
//
// PROVENANCE. Written from the published error-feedback modulator structure
// (a second-order noise shaper with two integrators and a 1-bit quantiser -
// the standard textbook form), NOT transcribed from sys/sigma_delta_dac.v.
// It is deliberately NOT bit-identical to that module, and no attempt was made
// to make it so: matching a GPL module cycle-for-cycle is how a rewrite turns
// back into a derivative work. What is preserved is the interface and the
// analog contract.
//
// THE CONTRACT, and why bit-exactness is the wrong bar here. This output is
// averaged by an RC filter before it reaches a speaker. What has to be right
// is the DC transfer (mean duty cycle must be a linear function of DACin over
// the full code range) and the in-band noise floor. Cycle-level agreement with
// some other modulator is not observable downstream. clash/tests/
// run_sigma_delta_tb.sh measures exactly those two properties.
//
// Second order is not a flourish. At this oversampling ratio a first-order
// shaper leaves audible in-band quantisation noise; the second integrator is
// what puts the noise floor below the 16-bit signal. See the SNR figure the
// testbench prints.
//
// DACin is offset binary ("excess 2**MSBI"), matching the call site in
// sys/audio_out.v, which presents {~sample[15], sample[14:0]}.

module nds_sigma_delta_dac #(parameter MSBI = 15, parameter INV = 1'b1)
(
   output reg      DACout,
   input  [MSBI:0] DACin,
   input           CLK,
   input           RESET
);

localparam W = MSBI + 4;   // headroom for two integrators without wrapping

// Offset binary -> signed, centred on zero, sign extended into the accumulators.
wire signed [W-1:0] sample = $signed({{(W-MSBI-1){1'b0}}, DACin}) -
                             $signed({{(W-MSBI-1){1'b0}}, {1'b1, {MSBI{1'b0}}}});

// Full-scale feedback: +/- 2**MSBI, i.e. the same amplitude the input spans.
localparam signed [W-1:0] FB = (1 <<< MSBI);

// Integrator clamp. A second-order loop with a 1-bit quantiser is only
// unconditionally stable for inputs well inside full scale; driven to the rails
// its integrators run away and the mean output collapses toward mid-scale
// instead of tracking the input. Measured, before this clamp existed: code 0
// produced a duty of 0.428 where it must produce ~1.0. Bounding both
// integrators restores tracking at the rails while leaving the noise shaping
// untouched in the range where the loop is linear - the standard fix, and the
// reason full-scale range does not have to be traded away for stability.
localparam signed [W-1:0] LIM = (3 <<< MSBI);

function automatic signed [W-1:0] clamp(input signed [W-1:0] x);
   begin
      if      (x >  LIM) clamp =  LIM;
      else if (x < -LIM) clamp = -LIM;
      else               clamp =  x;
   end
endfunction

reg signed [W-1:0] int1, int2;

always @(posedge CLK) begin
   reg signed [W-1:0] fb;
   reg signed [W-1:0] d1, d2;

   if (RESET) begin
      int1   <= 0;
      int2   <= 0;
      DACout <= INV ? 1'b1 : 1'b0;
   end else begin
      // Quantiser decision from the second integrator's sign: the output bit
      // is the 1-bit estimate, and the same value is subtracted back out of
      // both integrators, which is what shapes the error to high frequency.
      fb = int2[W-1] ? -FB : FB;

      d1 = clamp(int1 + sample - fb);   // first integrator
      d2 = clamp(int2 + d1     - fb);   // second integrator

      int1   <= d1;
      int2   <= d2;
      // Sample the sign that PRODUCED fb (int2 before the update), not the
      // post-update value: the output bit must be the quantiser decision the
      // loop just fed back, or the output is delayed by one sample relative to
      // the error it is meant to represent.
      DACout <= INV ? int2[W-1] : ~int2[W-1];
   end
end

endmodule
