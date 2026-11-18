-- | Native checker for the TARDIS monad.
--
-- Checks the two one-way reads and writes, the running semantics, and the
-- monad/applicative laws that the one-pass frame engine relies on. A failure
-- prints the offending case and exits non-zero.
module Main (main) where

import System.Exit (exitFailure)

import qualified Nds.Gpu2D.Tardis as T

main :: IO ()
main = do
  let failures = concat
        [ checkPure
        , checkPast
        , checkFuture
        , checkBackwardChain
        , checkFunctor
        , checkApplicative
        , checkMonad
        ]
  mapM_ (putStrLn . ("FAIL " ++)) failures
  putStrLn ("tardis-check: 7 groups, " ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure

checkPure :: [String]
checkPure =
  [ "pure: " ++ show got
  | got /= (42 :: Int, 0)
  ]
  where got = T.runTardis (0, 0) (pure (42 :: Int))

checkPast :: [String]
checkPast =
  [ "past: " ++ show got
  | got /= (2, 2 :: Int)
  ] ++
  [ "past-single: " ++ show got7
  | got7 /= (7, 7 :: Int)
  ]
  where
    got = T.runTardis (0, 0)
      (T.sendPast (1 :: Int) >> T.sendPast 2 >> T.getPast)
    got7 = T.runTardis (0, 0) (T.sendPast (7 :: Int) >> T.getPast)

checkFuture :: [String]
checkFuture =
  [ "future-empty: " ++ show got
  | got /= (5 :: Int, 0)
  ]
  where got = T.runTardis (0, 5) (T.getFuture :: T.Tardis Int Int Int)

checkBackwardChain :: [String]
checkBackwardChain =
  [ "backward: " ++ show got
  | got /= (3, 0)
  ]
  where
    got = T.runTardis (0, 5)
      ((T.getFuture >>= \x -> T.sendFuture (3 :: Int) >> pure x)
        :: T.Tardis Int Int Int)

checkFunctor :: [String]
checkFunctor =
  [ "functor: " ++ show got
  | got /= (2, 0)
  ]
  where got = T.runTardis (0, 0) (fmap (+ 1) (pure (1 :: Int)))

checkApplicative :: [String]
checkApplicative =
  [ "applicative: " ++ show got
  | got /= (3, 0)
  ]
  where
    got = T.runTardis (0, 0)
      (pure (+) <*> pure (1 :: Int) <*> pure (2 :: Int))

checkMonad :: [String]
checkMonad =
  [ "monad: " ++ show got
  | got /= (2, 0)
  ]
  where
    got = T.runTardis (0, 0)
      (pure (1 :: Int) >>= \x -> pure (x + 1))
