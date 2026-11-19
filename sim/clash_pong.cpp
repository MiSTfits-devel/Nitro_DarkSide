// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vhs_pong.h"
#include <cstdlib>
#include <iostream>

namespace {
constexpr unsigned down = 1u << 2, up = 1u << 3, serve = 1u << 4;
constexpr unsigned cyan = 0x43e5f5, pink = 0xfd5e92, ball = 0xfff2c4;
constexpr unsigned empty = 0x27344c, idleBorder = 0x31415d;

void check(bool pass, const char* message) {
    if (!pass) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

struct Frame {
    int left = -1, right = -1, bx = -1, by = -1;
    unsigned leftBars = 0, rightBars = 0, border = 0;
    bool serveCue = false;
};

class Sim {
    Vhs_pong core;

    unsigned cycle() {
        core.clk = 0;
        core.eval();
        core.clk = 1;
        core.eval();
        return core.video;
    }

public:
    void reset() {
        core.joy1 = core.joy2 = core.two_players = 0;
        core.reset = 1;
        cycle();
        cycle();
        core.reset = 0;
    }

    Frame scan(unsigned p1 = 0, unsigned p2 = 0, bool two = false, bool syncCheck = false) {
        core.joy1 = p1;
        core.joy2 = p2;
        core.two_players = two;
        Frame frame;
        int leftPixels = 0, rightPixels = 0, ballRows = 0;
        for (int y = 0; y < 525; ++y) {
            int creamPixels = 0, creamStart = -1;
            for (int x = 0; x < 800; ++x) {
                const unsigned idle = cycle();
                const unsigned sample = cycle();
                const unsigned rgb = sample & 0xffffff;
                if (syncCheck) {
                    const unsigned flags = 8 | (x < 640 && y < 480 ? 4 : 0)
                                             | (x >= 656 && x < 752 ? 2 : 0)
                                             | (y >= 490 && y < 492 ? 1 : 0);
                    check((sample >> 24) == flags, "640x480 raster flags or CE phase");
                    check(idle == (sample & 0x7ffffff), "same RGB and sync during both pixel phases");
                    check((flags & 4) || !rgb, "RGB must be black during blanking");
                }
                if (rgb == ball) {
                    if (creamStart < 0) creamStart = x;
                    ++creamPixels;
                }
                if (x == 24 && y >= 12 && y < 468 && rgb == cyan) {
                    if (frame.left < 0) frame.left = y + 35;
                    ++leftPixels;
                }
                if (x == 614 && y >= 12 && y < 468 && rgb == pink) {
                    if (frame.right < 0) frame.right = y + 35;
                    ++rightPixels;
                }
                if (y == 21) {
                    if (x >= 194 && x <= 258 && ((x - 194) & 15) == 0) {
                        check(rgb == cyan || rgb == empty, "left score marker color");
                        if (rgb == cyan) ++frame.leftBars;
                    }
                    if (x >= 370 && x <= 434 && ((x - 370) & 15) == 0) {
                        check(rgb == pink || rgb == empty, "right score marker color");
                        if (rgb == pink) ++frame.rightBars;
                    }
                }
                if (x == 1 && y == 1) frame.border = rgb;
                if (x == 307 && y == 227) frame.serveCue = rgb == ball;
            }
            if (creamPixels == 8) {
                if (frame.bx < 0) {
                    frame.bx = creamStart + 4;
                    frame.by = y + 4;
                }
                check(creamStart + 4 == frame.bx && y == frame.by - 4 + ballRows,
                      "ball must be one continuous 8x8 sprite");
                ++ballRows;
            } else {
                const bool clipped = creamPixels > 0 && creamPixels < 8 &&
                                     (creamStart < 36 || creamStart >= 604);
                check((creamPixels == 26 && (y == 227 || y == 252)) || !creamPixels || clipped,
                      "unexpected ball or serve indicator shape");
            }
        }
        check(leftPixels == 70 && rightPixels == 70, "both paddles remain 12x70");
        check(ballRows == (frame.bx < 0 ? 0 : 8), "ball height");
        return frame;
    }
};
}

int main() {
    Sim sim;
    sim.reset();
    const auto idle = sim.scan(up, down, false, true);
    check(idle.left == 240 && idle.right == 240 && idle.bx == 320 && idle.by == 240 &&
          idle.serveCue && idle.leftBars == 0 && idle.rightBars == 0 && idle.border == idleBorder,
          "reset draws court, paddles, centered ball, empty scores and serve cue");
    auto frame = sim.scan(serve, down);
    check(frame.left == 233 && frame.right == 240, "P1 up works; P2 is ignored in CPU mode");
    frame = sim.scan();
    check(frame.bx == 320 && !frame.serveCue, "P1 releases the serve");
    frame = sim.scan();
    check(frame.bx == 326 && frame.by == 242, "served ball advances");
    bool cpuReturned = false;
    for (int i = 0; i < 52; ++i) {
        const int previousX = frame.bx;
        frame = sim.scan();
        cpuReturned |= frame.bx < previousX && frame.bx > 550 && frame.right > 270;
    }
    check(cpuReturned, "CPU mode tracks and returns first serve");

    sim.reset();
    sim.scan(down, down, true);
    frame = sim.scan(0, down, true);
    check(frame.left == 247 && frame.right == 247, "both players have independent paddle inputs");
    for (int i = 0; i < 7; ++i) sim.scan(0, down, true);
    sim.scan(0, serve, true);
    frame = sim.scan(0, 0, true);
    check(!frame.serveCue && frame.right == 303, "P2 action serves in two-player mode");
    bool hitPaddle = false, hitWall = false;
    for (int i = 0; i < 90; ++i) {
        const auto prev = frame;
        frame = sim.scan(0, 0, true);
        hitPaddle |= frame.bx < prev.bx && frame.bx > 550;
        hitWall |= hitPaddle && prev.by >= 462 && frame.by < prev.by;
    }
    check(hitPaddle && hitWall, "paddle edge reflects ball and steers it into a wall bounce");

    sim.reset();
    for (unsigned point = 1; point <= 5; ++point) {
        sim.scan(0, up, true);
        for (int i = 0; i < 56; ++i) frame = sim.scan(serve, up, true);
        check(frame.right == 47 && frame.leftBars == point && frame.rightBars == 0,
              "P2 up clamps at court edge; only the scoring side gains one slot");
        if (point < 5) {
            check(frame.bx == 320 && frame.serveCue && frame.border == idleBorder,
                  "held Serve cannot auto-launch or auto-score after a miss");
        }
    }
    check(frame.border == cyan && frame.bx == -1, "first to five wins, shows winner and hides ball");
    sim.scan(0, 0, true);
    sim.scan(serve, 0, true);
    frame = sim.scan(serve, 0, true);
    check(frame.leftBars == 0 && frame.right == 240 && frame.bx == 320 && frame.serveCue,
          "fresh Serve on victory resets the match but does not launch the ball");
    std::cout << "PASS generated Pong Verilog: 640x480 timing, 2P input, CPU return, paddle and wall bounce, scores, serve latch, victory/restart\n";
}
