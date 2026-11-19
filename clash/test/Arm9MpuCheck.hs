-- SPDX-License-Identifier: GPL-3.0-or-later
-- Independent ARM946 MPU oracle: integer intervals (including 2^32),
-- highest-region-first list traversal and explicit AP permission sets.
{-# LANGUAGE DataKinds #-}
module Main where

import Clash.Prelude (BitVector)
import Control.Monad (forM_, unless)
import Data.Bits
import Data.List (find, foldl')
import qualified Nds.WholeCore.Arm9Mpu as M

type W = BitVector 32
instruction :: Bool -> Int -> Int -> Int -> W
instruction rd crn crm sub = 0xee000f10 .|. (if rd then bit 20 else 0) .|.
  shiftL (fromIntegral crn) 16 .|. fromIntegral crm .|. shiftL (fromIntegral sub) 5

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

selectors :: IO ()
selectors = do
  let good rd n m s = case n of
        2 -> m==0 && s<=1
        3 -> m==0 && s==0
        5 -> m==0 && s<=3
        6 -> m<8 && (s==0 || (rd && s==1))
        _ -> False
  forM_ [(r,n,m,s)|r<-[False,True],n<-[0..15],m<-[0..15],s<-[0..7]] $ \(rd,n,m,s) -> do
    let op=instruction rd n m s
    check ("selector "++show (rd,n,m,s)) (M.isMpuTransfer op==good rd n m s)
    if good rd n m s then do
      forM_ [4,8,9,10,11,21,22,23,24,25,26,27] $ \k ->
        check ("unrelated CP15 encoding "++show k) (not (M.isMpuTransfer (complementBit op k)))
      check "condition and Rd handled upstream" (M.isMpuTransfer (op `xor` 0xf000f000))
    else pure ()

transfer :: M.Mpu -> Int -> Int -> Int -> W -> M.Mpu
transfer m n reg sub v = if M.validMpuWrite op v then M.writeMpu m op v else error "invalid oracle setup"
 where op=instruction False n reg sub
rdreg :: M.Mpu -> Int -> Int -> Int -> W
rdreg m n reg sub = M.readMpu m (instruction True n reg sub)

descriptor :: Integer -> Int -> Bool -> W
descriptor base bits enabled=fromInteger base + fromIntegral (2*(bits-1)) + (if enabled then 1 else 0)
packing :: IO ()
packing = do
  forM_ [0,1] $ \kind -> do
    let nibbles=[6,5,3,2,1,4,7,15]::[Integer]
        packed=fromInteger . sum $ zipWith (\i x -> shiftL x (4*i)) [0..] nibbles
        basic=fromInteger . sum $ zipWith (\i x -> shiftL (x `mod` 4) (2*i)) [0..] nibbles
        m=transfer M.resetMpu 5 0 (2+kind) packed
    check "extended + basic views" (rdreg m 5 0 (2+kind)==packed && rdreg m 5 0 kind==basic)
    let newPs=[3,0,2,1,2,3,0,1]::[Integer]
        lowBits=fromInteger . sum $ zipWith (\i x -> shiftL x (2*i)) [0..] newPs
        nibBits=fromInteger . sum $ zipWith (\i x -> shiftL x (4*i)) [0..] newPs
        m'=transfer m 5 0 kind (0xabcd0000 .|. lowBits)
    check "legacy clears stale upper AP bits, other space unchanged" (rdreg m' 5 0 (2+kind)==nibBits && rdreg m' 5 0 (3-kind)==0)
  let attr=transfer (transfer (transfer M.resetMpu 2 0 0 0x123450ab) 2 0 1 0xffff0055) 3 0 0 0x211001ca
  check "eight attribute bits, independent I/D and buffer" (map (\(n,s)->rdreg attr n 0 s) [(2,0),(2,1),(3,0)] == [0xab,0x55,0xca])
  forM_ [0..7] $ \i -> do
    let v=descriptor (0x12000000+0x10000*toInteger i) 15 True
        m=transfer M.resetMpu 6 i 0 (v .|. 0xfc0)
    check "c6 raw and MRC legacy view, reserved bits RAZ" (rdreg m 6 i 0==v && rdreg m 6 i 1==v)
    check "c6 alternate write rejected" (not (M.validMpuWrite (instruction False 6 i 1) v))
    forM_ [0..10] $ \size -> do
      let short=fromIntegral (2*size+1 :: Int)
      check "undersize rejected only if enabled" (not (M.validMpuWrite (instruction False 6 i 0) short) && M.validMpuWrite (instruction False 6 i 0) (short-1))
    forM_ [13..32] $ \size -> check "unaligned enabled region rejected" (not (M.validMpuWrite (instruction False 6 i 0) (descriptor 0x1000 size True)))

-- Description directly in byte units. The range check never uses the
-- DUT's mask math and never wraps the upper threshold at 0x1_0000_0000.
data Region = R Integer Int Bool Int Int deriving Show -- base, log2(length), enable, D AP, I AP
install :: [Region] -> M.Mpu
install rs= transfer (transfer descriptors 5 0 2 (packAP False)) 5 0 3 (packAP True)
 where descriptors=foldl' (\m (i,R b k on _ _) -> transfer m 6 i 0 (descriptor b k on)) M.resetMpu (zip [0..] rs)
       packAP code=sum [shiftL (fromIntegral (if code then cap else dap)) (4*i) | (i,R _ _ _ dap cap)<-zip [0..] rs]

permission :: Int -> Bool -> Bool -> Bool
permission ap user wr = ap `elem` case (user,wr) of
  (False,False)->[1,2,3,5,6]
  (False,True) ->[1,2,3]
  (True,False) ->[2,3,6]
  (True,True)  ->[3]

oracle :: [Region] -> Integer -> Bool -> Bool -> Bool -> Bool
oracle rs a user code wr = case find covers (reverse rs) of
  Nothing -> False
  Just (R _ _ _ dap cap) -> not (code && wr) && permission (if code then cap else dap) user wr
 where covers (R b k on _ _) = on && b<=a && a<b+2^k

probe :: [Region] -> [Integer] -> IO ()
probe rs addresses=do
  let m=install rs
  forM_ [ (a,u,c,w) | a<-addresses,a>=0,a<2^32,u<-[False,True],c<-[False,True],w<-[False,True]] $ \(a,u,c,w) ->
    unless (M.allowed m u c w (fromInteger a)==oracle rs a u c w) $
      fail ("wrong permission at "++show (a,u,c,w)++" for "++show rs)

main :: IO ()
main = do
  selectors
  packing
  probe [] [0,0xffffffff,0x02001000]
  forM_ [12..32] $ \k -> do
    let bytes=2^k
        bases=[0, 2^32-bytes, (0x81234000 `div` bytes)*bytes]
    forM_ bases $ \b -> probe [R b k True 2 5] [b-1,b,b+1,b+bytes `div` 2,b+bytes-1,b+bytes,0,0xffffffff]
  forM_ [0..15] $ \ap -> probe [R 0 32 True ap (15-ap)] [0x02000ffc]
  -- Every priority pair in both deny/allow directions. A disabled higher
  -- slot cannot hide a lower one; a matching reserved permission must.
  forM_ [(i,j,on,ap) | i<-[0..6],j<-[i+1..7],on<-[False,True],ap<-[0,1,2,3,4,5,6,7,15]] $ \(i,j,on,ap) -> do
    let region n | n==i=R 0x02000000 22 True (if ap==3 then 0 else 3) 1
                 | n==j=R 0x023ff000 12 on ap 6
                 | otherwise=R 0 12 False 0 0
    probe (map region [0..7]) [0x01ffffff,0x02000000,0x023fefff,0x023ff000,0x023fffff,0x02400000]
  putStrLn "PASS: ARM946 exact selectors; AP legacy/extended views, all permission classes; all 21 legal sizes through 4 GiB; all 28 priority pairs, boundaries, disabled/no-match and malformed descriptors"
