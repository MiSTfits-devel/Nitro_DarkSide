# Haskell Pong for MiSTer

Standalone DE10-Nano core. Clash Haskell implements the game, CPU opponent, and 640×480 raster (800×525 total, 25 MHz pixel enable). SystemVerilog connects the game to the MiSTer controller and video shell. It is not an NDS core; it needs no ROM, BIOS, or SDRAM expansion module. The build has not been tested on a physical board.

## Play

Copy `HaskellPong.rbf` to a core folder on the MiSTer SD card, such as `_Other`, and select it from the MiSTer core menu. Use normal scaled HDMI for the first hardware trial.

- **D-pad Up/Down:** move your paddle. Player 1 is cyan on the left; Player 2 is pink on the right.
- **Serve:** press the first mapped action button (usually **A**) to launch the ball. In two-player mode, either controller can serve. Release and press again after a point; holding the button does not auto-serve.
- **Players:** defaults to **1 (vs CPU)**. Choose **2** in the core menu for local multiplayer with a second controller.
- First to five wins. The border shows the winner's color. Press **Serve** once to start a new match, then press again to serve. **Reset match** in the core menu clears the score at any time.

## Reproduce the simulation and build

From the repository root, with Stack/Clash and Verilator available:

```sh
work=$(mktemp -d)
bash sim/run_clash_pong.sh "$work/project"
(cd "$work/project" && quartus_sh --flow compile HaskellPong)
```

Without the directory argument, the launcher only generates and tests the fresh Verilog and cleans its temporary work. With the argument, it stages the exact tested Verilog and the allowlisted MiSTer shell in the new project directory. The simulation drives controller inputs and observes the generated raster for timing, CPU return, paddle and wall collisions, scoring, serve latching, victory, and restart.

To generate and stage the HDL separately:

```sh
work=$(mktemp -d)
(cd clash && stack exec clash -- --verilog -isrc \
  -fclash-no-escaped-identifiers -outputdir "$work/hdl" src/Mister/Pong.hs)
bash fpga/mister_hs_pong/stage.sh \
  "$work/hdl/Mister.Pong.topEntity/hs_pong.v" "$work/project"
(cd "$work/project" && quartus_sh --flow compile HaskellPong)
```

The staged project is the only build input needed on a Quartus host. It contains the Pong adapter, project settings and generated netlist, plus checked-in shell sources read from `HEAD`. It does not contain the NDS tree, ROMs, or user configuration. In `output_files/`, check `HaskellPong.sta.summary`, `HaskellPong.fit.summary`, and `HaskellPong.asm.rpt` before using `HaskellPong.rbf`: the Quartus command can exit successfully even when TimeQuest reports negative slack.

## Measured build result

Quartus Prime Lite **17.0.2** fit and assembled the design for **5CSEBA6U23I7**: **6,321 / 41,910 ALMs (15%)**. Across reported TimeQuest corners, worst setup was **+0.673 ns**, hold **+0.082 ns**, recovery **+3.325 ns**, and removal **+0.448 ns**, with zero unconstrained clocks. The game clock's worst setup and hold were **+2.998 ns** and **+0.082 ns**.

Earlier builds were withheld: the raw board clock was rejected by the shell's PLL-only clock switch, and the first two fitted builds missed HDMI setup by **−0.508 ns** and **−0.616 ns**. The final build uses a 50 MHz PLL output for that switch and narrows the HDMI OSD counter through the shell's existing parameter; it does not relax timing constraints.

Delivered `HaskellPong.rbf` SHA-256: `1bff952e6a3b59d9f1094fad155e7788f918396405d7292103aa8b0b3372aa7e`.
