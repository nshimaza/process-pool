module Control.Concurrent.ProcessPoolSpec where

import Control.Concurrent.Supervisor hiding (length)
import Data.Functor
import Data.Maybe
import Data.Traversable
import UnliftIO
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Control.Concurrent.ProcessPool

{-# ANN module "HLint: ignore Reduce duplication" #-}

spec :: Spec
spec = do
    describe "Run" $ do
        it "does not start process when pool size is zero" $ do
            (poolQ, pool) <- newProcessPool 0
            withAsync pool $ \_ -> do
                maybeAsync <- run poolQ $ pure ()
                isNothing maybeAsync `shouldBe` True

        prop "does not start process when pool size is negative" $ \(Positive n) -> do
            (poolQ, pool) <- newProcessPool (-n)
            withAsync pool $ \_ -> do
                maybeAsync <- run poolQ $ pure ()
                isNothing maybeAsync `shouldBe` True

        prop "starts a temporary process only when pool reosurce is available" $ \(Positive poolSize) ->
            forAll (choose (1, 100)) $ \overshoot -> do
            (poolQ, pool) <- newProcessPool poolSize
            withAsync pool $ \_ -> do
                results <- for [1 .. (poolSize + overshoot)] $ \index -> do
                    trigger <- newEmptyMVar
                    mark <- newEmptyMVar
                    blocker <- newEmptyMVar
                    var <- newTVarIO Nothing
                    maybeAsync <- run poolQ $ do
                        readMVar trigger
                        atomically $ writeTVar var (Just index)
                        putMVar mark ()
                        readMVar blocker
                        pure ()
                    pure (maybeAsync, trigger, mark, blocker, var)
                let successfuls = filter (\(maybeAsync, _, _, _, _) -> isJust maybeAsync) results
                length successfuls `shouldBe` poolSize
                vars <- for successfuls (\(_, _, _, _, var) -> readTVarIO var)
                all isNothing vars `shouldBe` True
                vars2 <- for  successfuls (\(_, trigger, mark, _, var) -> putMVar trigger () *> readMVar mark *> readTVarIO var)
                vars2 `shouldBe` map Just [1 .. poolSize]

    describe "Sync" $ do
        prop "starts a temporary process when pool reosurce is available" $ \(Positive numRequest) ->
            forAll (choose (1, 100)) $ \headroom -> do
            (poolQ, pool) <- newProcessPool (numRequest + headroom)
            withAsync pool $ \_ -> do
                results <- for [1 .. numRequest] $ \index -> do
                    trigger <- newEmptyMVar
                    mark <- newEmptyMVar
                    blocker <- newEmptyMVar
                    var <- newTVarIO Nothing
                    maybeAsync <- run poolQ $ do
                        readMVar trigger
                        atomically $ writeTVar var (Just index)
                        putMVar mark ()
                        readMVar blocker
                        pure ()
                    pure (maybeAsync, trigger, mark, blocker, var)
                all (\(maybeAsync, _, _, _, _) -> isJust maybeAsync) results `shouldBe` True
                vars <- for results (\(_, _, _, _, var) -> readTVarIO var)
                all isNothing vars `shouldBe` True
                vars2 <- for  results (\(_, trigger, mark, _, var) -> putMVar trigger () *> readMVar mark *> readTVarIO var)
                vars2 `shouldBe` map Just [1 .. numRequest]
