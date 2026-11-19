{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- SPDX-License-Identifier: GPL-3.0-or-later
module Mister.Pong (topEntity) where

import Clash.Prelude

type Coord = Signed 11
type Score = Unsigned 3
type RGB = BitVector 24

data Game = Game
  { leftY, rightY, ballX, ballY, dx, dy :: Coord
  , leftScore, rightScore :: Score
  , serving, serveHeld :: Bool
  } deriving (Generic, NFDataX)

initialGame :: Game
initialGame = Game 240 240 320 240 6 2 0 0 True False

data Raster = Raster Bool Coord Coord
  deriving (Generic, NFDataX)

advanceRaster :: Raster -> Raster
advanceRaster (Raster pixel x y)
  | not pixel = Raster True x y
  | x < 799   = Raster False (x + 1) y
  | y < 524   = Raster False 0 (y + 1)
  | otherwise = Raster False 0 0

paddleHalf :: Coord
paddleHalf = 35

ballHalf :: Coord
ballHalf = 4

paddleMove :: BitVector 5 -> Coord
paddleMove buttons
  | testBit buttons 3 == testBit buttons 2 = 0
  | testBit buttons 3 = -7
  | otherwise = 7

movePaddle :: Coord -> Coord -> Coord
movePaddle y move = min 433 (max 47 (y + move))

cpuMove :: Game -> Coord
cpuMove game
  | target < rightY game - 11 = -3
  | target > rightY game + 11 = 3
  | otherwise = 0
 where
  target = if dx game > 0 && not (serving game) then ballY game else 240

bounceY :: Coord -> Coord -> Coord -> Coord
bounceY hitY paddleY outgoingY
  | hitY < paddleY - 17 = -4
  | hitY > paddleY + 17 = 4
  | outgoingY < 0 = -2
  | otherwise = 2

nextGame :: Game -> (BitVector 5, BitVector 5, Bool) -> Game
nextGame game (joy1, joy2, twoPlayers)
  | won = if pressed then initialGame {serveHeld = True} else game {serveHeld = serve}
  | serving game = paddles {serving = not pressed}
  | xCandidate < 0 = point (leftScore game) (rightScore game + 1) (-6)
  | xCandidate >= 640 = point (leftScore game + 1) (rightScore game) 6
  | hitLeft  = paddles {ballX = 36,  ballY = yNext, dx = 6,  dy = bounceY yNext lNext ySpeed}
  | hitRight = paddles {ballX = 603, ballY = yNext, dx = -6, dy = bounceY yNext rNext ySpeed}
  | otherwise = paddles {ballX = xCandidate, ballY = yNext, dy = ySpeed}
 where
  serve = testBit joy1 4 || (twoPlayers && testBit joy2 4)
  pressed = serve && not (serveHeld game)
  won = leftScore game == 5 || rightScore game == 5
  lNext = movePaddle (leftY game) (paddleMove joy1)
  rNext = movePaddle (rightY game) (if twoPlayers then paddleMove joy2 else cpuMove game)
  paddles = game {leftY = lNext, rightY = rNext, serveHeld = serve}
  point ls rs speed = paddles {ballX = 320, ballY = 240, dx = speed, dy = 2,
                              leftScore = ls, rightScore = rs, serving = True}
  xCandidate = ballX game + dx game
  yCandidate = ballY game + dy game
  (yNext, ySpeed)
    | yCandidate < 12 = (24 - yCandidate, negate (dy game))
    | yCandidate > 467 = (934 - yCandidate, negate (dy game))
    | otherwise = (yCandidate, dy game)
  overlap py = abs (yNext - py) < paddleHalf + ballHalf
  hitLeft = dx game < 0 && ballX game >= 36 && xCandidate < 36 && overlap lNext
  hitRight = dx game > 0 && ballX game <= 603 && xCandidate > 603 && overlap rNext

spanAt :: Coord -> Coord -> Coord -> Bool
spanAt origin width v = v >= origin && v < origin + width

court :: Game -> Coord -> Coord -> RGB
court game x y
  | x < 4 || x >= 636 || y < 4 || y >= 476 = victory 0x31415d
  | spanAt 192 80 x && spanAt 20 8 y && scoreMark = scoreColor (leftScore game) leftColor
  | spanAt 368 80 x && spanAt 20 8 y && scoreMark = scoreColor (rightScore game) rightColor
  | won && spanAt 280 80 x && spanAt 228 24 y = victory 0
  | spanAt 20 12 x && spanAt (leftY game - paddleHalf) (paddleHalf * 2) y = leftColor
  | spanAt 608 12 x && spanAt (rightY game - paddleHalf) (paddleHalf * 2) y = rightColor
  | not won && spanAt (ballX game - ballHalf) (ballHalf * 2) x
            && spanAt (ballY game - ballHalf) (ballHalf * 2) y = 0xfff2c4
  | serving game && not won && spanAt 307 26 x && (y == 227 || y == 252) = 0xfff2c4
  | spanAt 318 4 x && not (testBit y 3) = 0x27344c
  | y == 7 || y == 472 = 0x18243c
  | otherwise = 0x0b1327
 where
  leftColor = 0x43e5f5
  rightColor = 0xfd5e92
  won = leftScore game == 5 || rightScore game == 5
  victory normal = if leftScore game == 5 then leftColor
                   else if rightScore game == 5 then rightColor else normal
  -- Both slot strips start at a 16-pixel boundary; each slot is 12+4 pixels.
  scoreMark = (resize (bitCoerce x :: Unsigned 11) :: Unsigned 4) < 12
  scoreIndex base = resize (shiftR (bitCoerce (x - base) :: Unsigned 11) 4)
  scoreColor score color =
    let base = if x < 320 then 192 else 368
    in if (scoreIndex base :: Score) < score then color else 0x27344c

-- 25 MHz pixel enable from 50 MHz; 640x480 active, 800x525 total, 59.52 Hz.
-- MiSTer sync inputs are active high; its physical VGA output inverts them.
video :: Game -> Raster -> BitVector 28
video game (Raster pixel x y) = pack pixel ++# pack de ++# pack hs ++# pack vs ++# rgb
 where
  de = x < 640 && y < 480
  hs = spanAt 656 96 x
  vs = spanAt 490 2 y
  rgb = if de then court game x y else 0

{-# ANN topEntity (Synthesize
  { t_name = "hs_pong"
  , t_inputs = [PortName "clk", PortName "reset", PortName "joy1", PortName "joy2", PortName "two_players"]
  , t_output = PortName "video"
  }) #-}
topEntity
  :: Clock System -> Reset System
  -> Signal System (BitVector 5) -> Signal System (BitVector 5) -> Signal System Bool
  -> Signal System (BitVector 28)
topEntity clk rst joy1 joy2 twoPlayers = withClockResetEnable clk rst enableGen serial
 where
  serial :: HiddenClockResetEnable System => Signal System (BitVector 28)
  serial = register 0 (video <$> game <*> raster)
   where
    raster = register (Raster False 0 0) (advanceRaster <$> raster)
    endFrame (Raster pixel x y) = pixel && x == 799 && y == 524
    game = regEn initialGame (endFrame <$> raster) (nextGame <$> game <*> bundle (joy1, joy2, twoPlayers))
