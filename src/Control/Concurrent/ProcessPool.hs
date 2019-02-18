module Control.Concurrent.ProcessPool where

import           Control.Monad
import           Data.Default
import           Data.Functor
import           UnliftIO

import           Control.Concurrent.Supervisor

data PoolMessage
    = ProcDown ExitReason
    | Run (IO ()) (ServerCallback (Maybe (Async ())))
    | RunSync (IO ()) (ServerCallback (Maybe (Async ())))

type PoolQueue = Actor PoolMessage

newProcessPool :: Int -> IO (Actor PoolMessage, IO ())
newProcessPool maxProcs = do
    (workerSvQ, workerSv) <- newActor newSimpleOneForOneSupervisor
    (poolManQ, poolMan) <- newActor $ poolManager workerSvQ maxProcs
    (_, topSv) <- newActor $ newSupervisor OneForAll def
        [ newProcessSpec Permanent $ noWatch workerSv
        , newProcessSpec Permanent $ noWatch poolMan]
    pure (poolManQ, topSv)

poolManager :: SupervisorQueue -> Int -> ActorHandler PoolMessage ()
poolManager workerSvQ maxProcs inbox = do
    cleanupQueue
    go maxProcs
  where
    cleanupQueue = tryReceiveSelect isDown inbox >>= go
      where
        go Nothing  = pure ()
        go (Just _) = tryReceiveSelect isDown inbox >>= go

        isDown (ProcDown _) = True
        isDown _            = False

    go avail = do
        message <- receiveSelect (dontReceiveQueueOnNoResource avail) inbox
        go =<< case message of
            (ProcDown _)                        -> pure $ avail + 1
            (Run action cont)   | avail <= 0    -> cont Nothing $> avail
                                | otherwise     -> (startPocess action >>= cont) $> avail - 1
            (RunSync action cont)               -> (startPocess action >>= cont) $> avail - 1

    dontReceiveQueueOnNoResource avail (RunSync _ _)    | avail <= 0    = False
                                                        | otherwise     = True
    dontReceiveQueueOnNoResource _ _                                    = True

    startPocess action = do
        let spec = newProcessSpec Temporary $ watch (\reason _ -> send (Actor inbox) $ ProcDown reason) action
        newChild def workerSvQ spec

run :: PoolQueue -> IO () -> IO (Maybe (Async ()))
run pool action = join <$> call def pool (Run action)

runSync :: PoolQueue -> IO () -> IO (Maybe (Async ()))
runSync pool action = join <$> call def pool (RunSync action)

runAsync :: PoolQueue -> IO () -> (Maybe (Async ()) -> IO a) -> IO (Async a)
runAsync pool action cont = async $ runSync pool action >>= cont
