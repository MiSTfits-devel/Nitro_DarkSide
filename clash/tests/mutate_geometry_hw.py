#!/usr/bin/env python3
"""Mutation test for the geometry hardware gate (GeometryHwCheck).

Each mutant is one textual edit to src/Nds/Gpu3D/GeometryHw.hs applied to a
private copy of clash/src + clash/test; the checker is rebuilt and run on the
gate's directed stream, then (if that passes) on the random stream.
"""
import os, shutil, subprocess, sys

CLASH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.environ.get("TMPDIR", "/tmp") + "/geometry-hw-mutants"
DATA = os.environ.get("TMPDIR", "/tmp") + "/nds-gpu3d-geometry-hw-check"
OBJ = os.environ.get("TMPDIR", "/tmp") + "/nds-gpu3d-geometry-hw-check/obj"

M = [
 ("accumulator not reset at a chain's first term",
  "let sums = zipWith (\\a p -> (if first then 0 else a) + p) (hAcc h) (prods h)",
  "let sums = zipWith (\\a p -> a + p) (hAcc h) (prods h)"),
 ("matrix result taken from bit 11",
  "hi12 s = truncateB (s `shiftR` 12)", "hi12 s = truncateB (s `shiftR` 11)"),
 ("clip update = proj * pos",
  "PgClip -> (rdM2 rd !! j, rdM1 rd)", "PgClip -> (rdM1 rd !! j, rdM2 rd)"),
 ("vector matrix slot not flipped after a mode-2 product",
  "    let h' = flipPtr t h\n", "    let h' = if t == TVec then h else flipPtr t h\n"),
 ("PUSH stores into slot sp+1",
  "hSlot = truncateB (hPosSP x)", "hSlot = truncateB (hPosSP x + 1)"),
 ("stack read data one word early",
  "let w = truncateB (k - 1) :: Unsigned 4", "let w = truncateB k :: Unsigned 4"),
 ("diffuse term added when the light faces away",
  "difOf p = if lit then lowU p else 0", "difOf p = lowU p"),
 ("box far plane reads the unlatched attribute",
  "not (testBit (hCurAttr h0) 12)", "not (testBit (hPolyAttr h0) 12)"),
 ("X -W test strict",
  "insideNegX v = (v !! (0 :: Int)) >= negate (v !! (3 :: Int))",
  "insideNegX v = (v !! (0 :: Int)) > negate (v !! (3 :: Int))"),
 ("widened clip quotient shifted by 31",
  "divDone (truncateB (prod `shiftR` 32))", "divDone (truncateB (prod `shiftR` 31))"),
 ("tag test never names none",
  "isNone t = case t of\n  ANone -> True", "isNone t = case t of\n  ANone -> False"),
 ("VBlank releases the swap before its event is taken",
  "if giVblank i && hSwap h0 && isNothing (hOut h0)", "if giVblank i && hSwap h0"),
 ("acknowledge keeps the texture stack pointer",
  "hErr = False, hProjSP = False, hTexSP = False }", "hErr = False, hProjSP = False }"),
 ("gathered command runs one entry late",
  "in if cnt' >= n", "in if cnt' > n"),
 ("TEXCOORD mode-1 constant omits row 3",
  "hTexBias = zipWith (+) (hTexR2 h) tex2", "hTexBias = hTexR2 h"),
 ("test-busy low during VEC_TEST",
  "(hCmd h == 0x70 || hCmd h == 0x71 || hCmd h == 0x72)", "(hCmd h == 0x70 || hCmd h == 0x71)"),
 ("vertex emitted from the registers before the last delivery",
  "hOut = Just (vertexEvent h (giZeroDotW i))", "hOut = Just (vertexEvent h0 (giZeroDotW i))"),
 ("lit colour clamped before the last light lands",
  "hColor = map clamp (hLBuf h)", "hColor = map clamp (hLBuf h0)"),
 ("VECMTX_RESULT word 3 reads row 1 column 1",
  "  3 -> (1, 0)\n", "  3 -> (1, 1)\n"),
 ("shininess byte from index bits 1-2",
  "(8 * fromEnum (truncateB (shineIx h) :: Unsigned 2))", "(8 * fromEnum (truncateB (shineIx h `shiftR` 1) :: Unsigned 2))"),
 ("Y-pass segment does not interpolate W",
  "  1 -> 1\n  _ -> 0\n", "  1 -> 0\n  _ -> 0\n"),
 ("specular reciprocal sign dropped",
  "recip = if dvNeg (hDiv h0) then negate q else q", "recip = q"),
 ("SWAP_BUFFERS does not wait for VBlank",
  "hOut = Just (HeSwap (truncateB p0)), hSwap = True, hCtl = CIdle }", "hOut = Just (HeSwap (truncateB p0)), hCtl = CIdle }"),
 ("STORE to slot 31 sets no error",
  "in x { hErr = hErr x || a > 30, hSlot = a, hCtl = CStackW 0 }", "in x { hSlot = a, hCtl = CStackW 0 }"),
]

def run(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

def main():
    only = [int(a) for a in sys.argv[1:]]
    env = dict(os.environ)
    results = []
    for k, (name, old, new) in enumerate(M):
        if only and k not in only:
            continue
        d = f"{WORK}/m{k}"
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        run(f"cp -Rp {CLASH}/src {CLASH}/test {d}/ && cp -Rp {OBJ} {d}/obj")
        p = f"{d}/src/Nds/Gpu3D/GeometryHw.hs"
        s = open(p).read()
        n = s.count(old)
        if n != 1:
            results.append((k, name, f"BAD PATTERN ({n} matches)"))
            print(k, name, results[-1][2], flush=True)
            continue
        open(p, "w").write(s.replace(old, new))
        c = run(f"stack --resolver lts-22.43 ghc -- -O2 -threaded -rtsopts -i{d}/src -i{d}/test "
                f"-outputdir {d}/obj {d}/test/GeometryHwCheck.hs -o {d}/chk", env=env, cwd=CLASH)
        if c.returncode != 0:
            results.append((k, name, "COMPILE ERROR: " + c.stderr[-300:]))
            print(k, name, results[-1][2], flush=True)
            continue
        verdict = None
        for stage in ["directed", "random"]:
            r = run(f"{d}/chk check {DATA}/{stage}.bin 1 +RTS -N", env=env)
            last = (r.stdout.strip().splitlines() or [""])[-1]
            if r.returncode != 0:
                first = next((l for l in r.stdout.splitlines() if "stream" in l and ":" in l and "geometry-hw-check" not in l), "")
                verdict = f"killed by {stage}: {last.split(', ')[-1]} | {first[:140]}"
                break
        if verdict is None:
            verdict = "SURVIVED"
        results.append((k, name, verdict))
        print(k, name, "->", verdict, flush=True)
        shutil.rmtree(d, ignore_errors=True)
    print("\nsummary:")
    for k, name, v in results:
        print(f"{k} | {name} | {v}")

main()
