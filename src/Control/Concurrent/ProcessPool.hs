module Control.Concurrent.ProcessPool where

import           Control.Monad
import           Data.Default
import           Data.Functor
import           UnliftIO

import           Control.Concurrent.Supervisor

{-|
    `PoolMessage` defines all messages for pool manager actor.
    It follows Server behavior rule from async-supervisor package.
-}
data PoolMessage
    = ProcDown ExitReason                                   -- ^ Notification on process termination.
    | Run (IO ()) (ServerCallback (Maybe (Async ())))       -- ^ Request to run a process.  Returns `Async` on success, `Nothing` on supervisor timeout or pool is full.
    | RunSync (IO ()) (ServerCallback (Maybe (Async ())))   -- ^ Request to run a process.  Waits for available resource.  Returns `Async` on success, `Nothing` on timeout.

-- | Type sysnonym of pool manager actor's write-end queue.
type PoolQueue = Actor PoolMessage

-- | Create an actor of process pool
newProcessPool
    :: Int                              -- ^ Maximum number of processes runnable at a time.
    -> IO (Actor PoolMessage, IO ())
newProcessPool maxProcs = do
    (workerSvQ, workerSv) <- newActor newSimpleOneForOneSupervisor      -- Supervisor for worker processes.
    (poolManQ, poolMan) <- newActor $ poolManager workerSvQ maxProcs    -- Actor managing pool.
    (_, topSv) <- newActor $ newSupervisor OneForAll def                -- Top level actor.
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

{-|
    Request to run an IO action with pooled process.  Returns 'Async' on
    success.  Returns 'Nothing' if pool is full or process creation timed out.
-}
run :: PoolQueue -> IO () -> IO (Maybe (Async ()))
run pool action = join <$> call def pool (Run action)

{-|
    Request to run an IO action with pooled process.  Returns 'Async' on
    success.  Wait until resource becomes available.  Returns 'Nothing' on
    timoeout.
-}
runSync :: PoolQueue -> IO () -> IO (Maybe (Async ()))
runSync pool action = join <$> call def pool (RunSync action)

-- | Call runSync with wrapped by 'Async'.  Result (running process) is passed to continuation (callback).
runAsync :: PoolQueue -> IO () -> (Maybe (Async ()) -> IO a) -> IO (Async a)
runAsync pool action cont = async $ runSync pool action >>= cont
